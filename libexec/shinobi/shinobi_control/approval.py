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


def create(*, capability: str, arguments: dict[str, Any], profile: str, reason: str, ttl_seconds: int = 300) -> dict[str, Any]:
    now = dt.datetime.now(dt.timezone.utc)
    record = {
        "approval_id": secrets.token_hex(12),
        "capability": capability,
        "arguments": arguments,
        "profile": profile,
        "reason": reason,
        "state": "pending",
        "created_at": now.isoformat(),
        "expires_at": (now + dt.timedelta(seconds=ttl_seconds)).isoformat(),
    }
    root = approval_dir()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = root / f"{record['approval_id']}.json"
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
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
