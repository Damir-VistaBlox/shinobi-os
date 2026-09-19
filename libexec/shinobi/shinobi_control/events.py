"""Versioned local Shinobi event envelopes."""
from __future__ import annotations

import datetime as dt
import json
import os
import secrets
from pathlib import Path
from typing import Any


def event_path() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "shinobi/events.jsonl"


def publish(name: str, payload: dict[str, Any] | None = None, origin: str = "shinobi") -> dict[str, Any]:
    if not name or any(part == "" for part in name.split(".")):
        raise ValueError("event name must be dot-separated")
    event = {
        "event_version": 1,
        "event_id": secrets.token_hex(12),
        "event": name,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "origin": origin,
        "payload": payload or {},
    }
    path = event_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, sort_keys=True) + "\n")
    os.chmod(path, 0o600)
    return event


def recent(limit: int = 50) -> list[dict[str, Any]]:
    path = event_path()
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()[-limit:]
    return [json.loads(line) for line in lines if line.strip()]
