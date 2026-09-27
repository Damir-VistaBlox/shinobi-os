"""Durable, single-use approval records for agent requests."""
from __future__ import annotations

import datetime as dt
import json
import os
import secrets
from pathlib import Path
from typing import Any


def approval_dir() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/approvals"


def is_live_mode() -> bool:
    """True when running from the live image rather than an installed system.

    Mirrors the check in registry._status.
    """
    return Path("/run/live/medium/live/filesystem.squashfs").exists()


def create(*, capability: str, arguments: dict[str, Any], profile: str, reason: str, ttl_seconds: int = 300) -> dict[str, Any]:
    now = dt.datetime.now(dt.timezone.utc)
    record = {
        "approval_id": secrets.token_hex(12),
        "capability": capability,
        "arguments": arguments,
        "profile": profile,
        "reason": reason,
        "state": "pending",
        # Bound at request time and re-checked on consumption: an approval
        # granted on the live ISO should not be replayable against an
        # installed system, where the same capability has a different blast
        # radius.
        "live_mode": is_live_mode(),
        "created_at": now.isoformat(),
        "expires_at": (now + dt.timedelta(seconds=ttl_seconds)).isoformat(),
    }
    root = approval_dir()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = root / f"{record['approval_id']}.json"
    # Write via a private temp file and rename, so a reader never observes a
    # half-written approval.
    handle = os.open(path.with_suffix(".json.tmp"), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as f:
        f.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(path.with_suffix(".json.tmp"), path)
    os.chmod(path, 0o600)
    return record


def list_records() -> list[dict[str, Any]]:
    root = approval_dir()
    if not root.is_dir():
        return []
    records = []
    for path in sorted(root.glob("*.json")):
        try:
            records.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    return records


def get(approval_id: str) -> dict[str, Any]:
    path = approval_dir() / f"{approval_id}.json"
    if not path.is_file():
        raise FileNotFoundError(approval_id)
    return json.loads(path.read_text(encoding="utf-8"))


def set_state(approval_id: str, state: str) -> dict[str, Any]:
    if state not in {"approved", "denied", "cancelled"}:
        raise ValueError("invalid approval state")
    record = get(approval_id)
    if record.get("state") != "pending":
        raise ValueError(f"approval is already {record.get('state')}")
    record["state"] = state
    record["resolved_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    path = approval_dir() / f"{approval_id}.json"
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


class ApprovalError(RuntimeError):
    """An approval could not be claimed for the requested action."""


def _canonical(arguments: dict[str, Any]) -> str:
    return json.dumps(arguments, sort_keys=True, separators=(",", ":"))


def consume(approval_id: str, *, capability: str, arguments: dict[str, Any], profile: str | None = None) -> dict[str, Any]:
    """Claim an approved, unexpired, single-use approval for one exact call.

    An approval authorizes one specific action, not a capability in general, so
    the capability *and* the exact arguments must match. Without the argument
    check, approving `nmap -T4 10.0.0.5` would also authorize
    `nmap -T4 10.0.0.6` and `rm -rf /` under the same capability id.

    The claim is made with an O_EXCL create, so two concurrent callers cannot
    both consume the same approval: an approval is good for exactly one call.
    """
    if not approval_id or "/" in approval_id or "\\" in approval_id or approval_id.startswith("."):
        raise ApprovalError("invalid approval id")

    record = get(approval_id)

    if record.get("state") != "approved":
        raise ApprovalError(
            f"approval {approval_id} is {record.get('state')!r}, not approved"
        )

    expires_at = record.get("expires_at")
    if not expires_at:
        raise ApprovalError(f"approval {approval_id} has no expiry and cannot be claimed")
    try:
        deadline = dt.datetime.fromisoformat(expires_at)
    except ValueError as exc:
        raise ApprovalError(f"approval {approval_id} has an unparseable expiry") from exc
    if deadline.tzinfo is None:
        deadline = deadline.replace(tzinfo=dt.timezone.utc)
    if dt.datetime.now(dt.timezone.utc) >= deadline:
        raise ApprovalError(f"approval {approval_id} expired at {expires_at}")

    if record.get("capability") != capability:
        raise ApprovalError(
            f"approval {approval_id} is for capability {record.get('capability')!r}, "
            f"not {capability!r}"
        )
    if _canonical(record.get("arguments") or {}) != _canonical(arguments):
        raise ApprovalError(
            f"approval {approval_id} was granted for different arguments; "
            f"approved: {_canonical(record.get('arguments') or {})}, "
            f"requested: {_canonical(arguments)}"
        )
    if profile is not None and record.get("profile") != profile:
        raise ApprovalError(
            f"approval {approval_id} was granted to profile {record.get('profile')!r}, "
            f"not {profile!r}"
        )
    if record.get("live_mode") is not None and bool(record["live_mode"]) != is_live_mode():
        raise ApprovalError(
            f"approval {approval_id} was granted in "
            f"{'live' if record['live_mode'] else 'installed'} mode, "
            f"but this is {'live' if is_live_mode() else 'installed'} mode"
        )

    # Claim before returning, so a second call cannot also succeed.
    claim = approval_dir() / f"{approval_id}.claimed"
    try:
        handle = os.open(claim, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise ApprovalError(f"approval {approval_id} was already used") from exc
    try:
        os.write(
            handle,
            json.dumps(
                {
                    "claimed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                    "pid": os.getpid(),
                },
                sort_keys=True,
            ).encode(),
        )
    finally:
        os.close(handle)

    record["consumed_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    path = approval_dir() / f"{approval_id}.json"
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record
