"""Engagement scope loading, target authorization, and audit logging.

Every tool in server.py must call require_in_scope() before touching a
target, and log_call() after — allowed or refused. This module is the only
place that decides "is this target authorized," so it's the one place that
needs careful review, not each tool.
"""
from __future__ import annotations

import datetime as _dt
import ipaddress
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

import yaml

_HOSTNAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")


class ScopeError(RuntimeError):
    """Raised when a target is refused or the engagement is misconfigured."""


@dataclass(frozen=True)
class Engagement:
    name: str
    dir: Path

    @property
    def scope_file(self) -> Path:
        return self.dir / "scope.yaml"

    @property
    def log_file(self) -> Path:
        return self.dir / "log.jsonl"


def current_engagement() -> Engagement:
    name = os.environ.get("SHINOBI_ENGAGEMENT")
    dir_ = os.environ.get("SHINOBI_ENGAGEMENT_DIR")
    if not name or not dir_:
        raise ScopeError(
            "No active engagement (SHINOBI_ENGAGEMENT / SHINOBI_ENGAGEMENT_DIR not set). "
            "Launch this server via `shinobi agent` after `shinobi engagement use <name>`."
        )
    return Engagement(name=name, dir=Path(dir_))


def _load_scope(engagement: Engagement) -> dict:
    if not engagement.scope_file.exists():
        raise ScopeError(f"No scope file at {engagement.scope_file}")
    with engagement.scope_file.open() as f:
        data = yaml.safe_load(f) or {}
    return data


def _in_window(scope: dict) -> bool:
    window = scope.get("window") or {}
    try:
        start = _dt.date.fromisoformat(str(window.get("start")))
        end = _dt.date.fromisoformat(str(window.get("end")))
    except (TypeError, ValueError):
        # Unparseable (e.g. still "CHANGE ME") fails closed, not open.
        return False
    today = _dt.date.today()
    return start <= today <= end


def _target_matches(target: str, entry: str) -> bool:
    entry = entry.strip()
    try:
        target_ip = ipaddress.ip_address(target)
    except ValueError:
        target_ip = None

    if "/" in entry:
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError:
            return False
        return target_ip is not None and target_ip in network

    if target_ip is not None:
        try:
            return target_ip == ipaddress.ip_address(entry)
        except ValueError:
            return False

    # Hostname entry. Support a leading "*." for subdomain matches.
    if entry.startswith("*."):
        suffix = entry[1:]  # ".example.com"
        return target.lower().endswith(suffix.lower()) and target.lower() != suffix.lower().lstrip(".")
    return target.lower() == entry.lower()


def validate_target_syntax(target: str) -> None:
    """Reject anything that isn't a plain IP or hostname before it goes near scope
    checks or a subprocess argv — this is what stops a target string from
    doubling as a flag injection (e.g. "--script=...")."""
    try:
        ipaddress.ip_address(target)
        return
    except ValueError:
        pass
    if target.startswith("-") or not _HOSTNAME_RE.match(target):
        raise ScopeError(f"Refusing malformed target: {target!r}")


def require_in_scope(target: str) -> Engagement:
    validate_target_syntax(target)
    engagement = current_engagement()
    scope = _load_scope(engagement)

    if not _in_window(scope):
        raise ScopeError(
            f"Engagement '{engagement.name}' scope window is missing or invalid "
            f"in {engagement.scope_file} (edit window.start/window.end)."
        )

    targets = scope.get("targets") or []
    if not any(_target_matches(target, entry) for entry in targets):
        raise ScopeError(
            f"Target {target!r} is not in the authorized scope for engagement "
            f"'{engagement.name}' ({engagement.scope_file}). Refusing."
        )
    return engagement


def log_call(engagement: Engagement | None, tool: str, target: str, args: list[str], verdict: str, detail: str = "") -> None:
    """verdict: 'allowed' | 'refused'"""
    entry = {
        "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "tool": tool,
        "target": target,
        "args": args,
        "verdict": verdict,
        "detail": detail[:2000],
    }
    if engagement is None:
        # Refused before we could even resolve an engagement (e.g. env not
        # set) — nowhere safe to log to, so this must still reach stderr.
        print(f"shinobi-recon: {json.dumps(entry)}", flush=True)
        return
    with engagement.log_file.open("a") as f:
        f.write(json.dumps(entry) + "\n")
