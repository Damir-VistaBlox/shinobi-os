"""What the desktop panel shows about the engagement, in one read-only report.

The panel (Quickshell) is a place to look, not a place to decide. This module
gathers the three things it shows that no other command reports in one piece --
the active engagement and whether its scope can be used, the approvals waiting for a
human, and what the agent's tools have been doing -- and prints them as one JSON
document, so the panel makes one call and a test can hold the contract.

It changes nothing and decides nothing. In particular:

  * It never writes: not a record, not an audit line, not a state file. Opening
    the panel must leave no trace, and a status command that consumed an approval
    or created a directory would make "looking" a thing with consequences.
  * It reads the scope the way the gate does (egress.load_scope refuses a symlink,
    a file group- or world-writable, bad YAML), so a scope the gate would refuse is
    shown as a problem rather than as a list of targets that looks usable.
  * It reports only what is safe to put on a screen: approvals without their
    arguments, log records without their arguments or detail text. Those are one
    `shinobi approval show` / `shinobi egress trail` away, where the operator asks
    for them.

The window check here is for display. The gate's own check (the recon server's
scope module) is the one that authorizes, and this never substitutes for it.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any

MAX_TARGETS = 6
MAX_APPROVALS = 5
MAX_ACTIVITY = 8
# A log can be large after a long engagement; the newest records are at the end.
LOG_TAIL_BYTES = 128 * 1024
TEXT_LIMIT = 160


def _clip(value: Any, limit: int = TEXT_LIMIT) -> str:
    """A value as display text: a bounded string with no control characters."""
    text = "".join(ch if ch.isprintable() else " " for ch in str(value))
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _date(value: Any) -> dt.date | None:
    try:
        return dt.date.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


def _window(scope: dict[str, Any], today: dt.date) -> dict[str, Any]:
    window = scope.get("window")
    window = window if isinstance(window, dict) else {}
    start, end = _date(window.get("start")), _date(window.get("end"))
    if start is None or end is None:
        # "CHANGE ME" from the template, or nothing at all: the gate refuses this too.
        state = "invalid"
    elif today < start:
        state = "upcoming"
    elif today > end:
        state = "expired"
    else:
        state = "active"
    return {
        "start": start.isoformat() if start else None,
        "end": end.isoformat() if end else None,
        "state": state,
    }


def engagement(today: dt.date | None = None) -> tuple[dict[str, Any], Path | None]:
    """The active engagement as the panel shows it, and its directory when it has one."""
    from . import egress
    from .policy import current_engagement

    today = today or dt.date.today()
    name = current_engagement() or os.environ.get("SHINOBI_ENGAGEMENT", "").strip()
    report: dict[str, Any] = {
        "name": _clip(name, 64) if name else None,
        "state": "none",
        "problem": None,
        "window": None,
        "targets": [],
        "target_count": 0,
    }
    if not name:
        return report, None

    try:
        directory = egress._engagement_dir()
        scope = egress.load_scope(directory)
    except egress.EgressRefused as exc:
        # The gate's own words: they say what is wrong and how to fix it.
        report["state"] = "problem"
        report["problem"] = _clip(exc, 400)
        return report, None

    targets = scope.get("targets")
    targets = targets if isinstance(targets, list) else []
    report["state"] = "ready"
    report["window"] = _window(scope, today)
    report["targets"] = [_clip(t, 80) for t in targets[:MAX_TARGETS]]
    report["target_count"] = len(targets)
    return report, directory


def approvals(now: dt.datetime | None = None) -> dict[str, Any]:
    """Approvals waiting for a human: pending and not yet expired, oldest first."""
    from . import approval

    now = now or dt.datetime.now(dt.timezone.utc)
    waiting = []
    for record in approval.list_records():
        if not isinstance(record, dict) or record.get("state") != "pending":
            continue
        try:
            expires = dt.datetime.fromisoformat(str(record.get("expires_at")))
        except ValueError:
            continue
        if expires.tzinfo is None or expires <= now:
            continue
        waiting.append((str(record.get("created_at", "")), record, expires))
    waiting.sort(key=lambda item: item[0])
    return {
        "pending_count": len(waiting),
        "pending": [
            {
                "approval_id": _clip(record.get("approval_id", ""), 64),
                "capability": _clip(record.get("capability", ""), 80),
                "reason": _clip(record.get("reason", ""), 120),
                "profile": _clip(record.get("profile", ""), 24),
                "expires_at": expires.isoformat(),
            }
            for _, record, expires in waiting[:MAX_APPROVALS]
        ],
    }


def _tail_lines(path: Path) -> list[str]:
    """The last lines of a log, without following a link and without reading it all."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return []
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            return []
        size = stream.seek(0, os.SEEK_END)
        stream.seek(max(0, size - LOG_TAIL_BYTES))
        data = stream.read()
    lines = data.decode("utf-8", errors="replace").splitlines()
    # The first line of a tail that started mid-file is a fragment.
    return lines[1:] if size > LOG_TAIL_BYTES else lines


def activity(directory: Path | None) -> list[dict[str, Any]]:
    """What the engagement's tools last did, newest first, one row per call.

    A call writes an `intent` record before it runs and a `result` record after, and
    only the pair tells the story: an intent with no result is a call still running,
    or one that was killed, and the panel says "started" rather than leave it out.
    """
    if directory is None:
        return []
    calls: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for line in _tail_lines(directory / "log.jsonl"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or not record.get("tool"):
            continue
        call_id = str(record.get("call_id") or f"line-{len(order)}")
        if call_id not in calls:
            order.append(call_id)
        elif record.get("phase") == "intent":
            continue  # an intent never overwrites the result it came before
        calls[call_id] = record

    rows = []
    for call_id in reversed(order[-MAX_ACTIVITY:]):
        record = calls[call_id]
        started = record.get("phase") == "intent"
        rows.append(
            {
                "time": _clip(record.get("ts", ""), 40),
                "tool": _clip(record.get("tool", ""), 48),
                "target": _clip(record.get("target", ""), 80),
                "verdict": "started" if started else _clip(record.get("verdict", ""), 16),
            }
        )
    return rows


def report() -> dict[str, Any]:
    from .policy import current_profile

    scope, directory = engagement()
    return {
        "version": 1,
        "engagement": scope,
        "profile": current_profile(),
        "approvals": approvals(),
        "activity": activity(directory),
    }


def _print_text(data: dict[str, Any]) -> None:
    scope = data["engagement"]
    if scope["state"] == "none":
        print("engagement: none (shinobi engagement use <name>)")
    elif scope["state"] == "problem":
        print(f"engagement: {scope['name']}: cannot be used: {scope['problem']}")
    else:
        window = scope["window"]
        print(f"engagement: {scope['name']}  window {window['state']} ({window['start']} .. {window['end']})")
        shown = ", ".join(scope["targets"]) or "none"
        more = scope["target_count"] - len(scope["targets"])
        print(f"targets:    {scope['target_count']}: {shown}" + (f" (+{more} more)" if more > 0 else ""))
    print(f"profile:    {data['profile']}")
    waiting = data["approvals"]
    print(f"approvals:  {waiting['pending_count']} waiting")
    for item in waiting["pending"]:
        print(f"  - {item['approval_id']}  {item['capability']}  {item['reason']}")
    if data["activity"]:
        print("activity:")
        for row in data["activity"]:
            print(f"  {row['time']}  {row['tool']}  {row['target']}  {row['verdict']}")


def main(argv: list[str]) -> int:
    action = argv[0] if argv else "status"
    as_json = "--json" in argv[1:]
    if action in {"-h", "--help", "help"}:
        print("Usage: shinobi panel status [--json]")
        print()
        print("  status   the engagement, the approvals waiting for you, and what the")
        print("           agent's tools last did: what the desktop panel shows.")
        print("           Read-only: it writes nothing and decides nothing.")
        return 0
    if action != "status":
        print(f"shinobi-panel: unknown action '{action}'", file=sys.stderr)
        return 2
    try:
        data = report()
    except Exception as exc:  # noqa: BLE001 - a status command must not traceback at a panel
        print(f"shinobi-panel: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    if as_json:
        print(json.dumps(data, sort_keys=True))
    else:
        _print_text(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
