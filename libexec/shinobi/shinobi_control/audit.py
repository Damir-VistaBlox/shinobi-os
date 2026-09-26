"""Append-only local audit journal for control-plane requests."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import secrets
from pathlib import Path
from typing import Any


def audit_path() -> Path:
    override = os.environ.get("SHINOBI_AUDIT_FILE")
    if override:
        return Path(override)
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/audit.jsonl"


def _hash_arguments(arguments: dict[str, Any]) -> str:
    payload = json.dumps(arguments, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def write(
    *,
    actor: str,
    capability: str,
    arguments: dict[str, Any],
    status: str,
    detail: str = "",
    request_id: str = "",
    references: dict[str, str] | None = None,
) -> str:
    """Append one audit record and return its audit id.

    `arguments` is recorded only as a hash, so an argument that carried
    something sensitive left nothing behind. That leaves a gap for callers that
    need a *specific* digest to be correlatable -- the egress gate hashes a
    prompt so the text never lands anywhere, and then has no way to say in this
    journal which prompt it was. `references` carries named digests and ids
    that are already safe to store, as structured fields rather than prose
    packed into `detail`.
    """
    audit_id = secrets.token_hex(12)
    entry = {
        "audit_version": 1,
        "audit_id": audit_id,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "actor": actor,
        "capability": capability,
        "arguments_hash": _hash_arguments(arguments),
        "request_id": request_id,
        "status": status,
        "detail": detail[:2000],
    }
    if references:
        entry["references"] = {str(k): str(v)[:200] for k, v in sorted(references.items())}
    path = audit_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(entry, sort_keys=True) + "\n")
    os.chmod(path, 0o600)
    return audit_id
