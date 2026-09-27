"""Capability registry and safe built-in handlers."""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .protocol import ProtocolError


@dataclass(frozen=True)
class Capability:
    id: str
    summary: str
    risk: str
    privilege: str
    requires_engagement: bool
    requires_approval: bool
    live_mode: bool
    audit: bool
    timeout: int
    handler: Callable[[dict[str, Any]], dict[str, Any]]


def _status(_: dict[str, Any]) -> dict[str, Any]:
    return {
        "shinobi_version": _read_version(),
        "kernel": platform.release(),
        "hostname": platform.node(),
        "live": Path("/run/live/medium/live/filesystem.squashfs").exists(),
        "user": os.environ.get("USER", ""),
    }


def _read_version() -> str:
    for path in (Path("/usr/share/shinobi/version"), Path(__file__).parents[3] / "packaging/shinobi-core/usr/share/shinobi/version"):
        try:
            return path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
    return "unknown"


def _desktop_notify(arguments: dict[str, Any]) -> dict[str, Any]:
    title = arguments.get("title", "Shinobi")
    body = arguments.get("body", "")
    if not isinstance(title, str) or not isinstance(body, str) or len(title) > 256 or len(body) > 4096:
        raise ProtocolError("title/body must be bounded strings")
    notify = shutil.which("notify-send")
    if notify:
        subprocess.run([notify, "-t", "5000", title, body], check=False, timeout=10)
    return {"title": title, "body": body, "delivered": bool(notify)}


def _context_snapshot(_: dict[str, Any]) -> dict[str, Any]:
    return {
        "session": {
            "wayland_display": bool(os.environ.get("WAYLAND_DISPLAY")),
            "desktop": os.environ.get("XDG_CURRENT_DESKTOP", ""),
            "live": Path("/run/live/medium/live/filesystem.squashfs").exists(),
        },
        "theme": _read_user_value("theme"),
        "engagement": _read_current_engagement(),
    }


def _read_user_value(name: str) -> str:
    path = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "shinobi" / name
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _read_current_engagement() -> str:
    path = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/current-engagement"
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def builtin_capabilities() -> dict[str, Capability]:
    # Keyword arguments on purpose. These were positional, and all three
    # capabilities had live_mode=True copied down the line -- a field nothing
    # read, so nobody noticed. When live_mode started being enforced, an
    # installed system could no longer send a desktop notification or read its
    # own status. None of these three is live-specific: they are read-only or
    # benign, and _status reports whether it is on the live image as part of its
    # own result, so it clearly expects to run in both places.
    return {
        "system.status": Capability(
            id="system.status",
            summary="Read Shinobi and host status",
            risk="low",
            privilege="unprivileged",
            requires_engagement=False,
            requires_approval=False,
            live_mode=False,
            audit=True,
            timeout=10,
            handler=_status,
        ),
        "desktop.notify": Capability(
            id="desktop.notify",
            summary="Display a desktop notification",
            risk="low",
            privilege="unprivileged",
            requires_engagement=False,
            requires_approval=False,
            live_mode=False,
            audit=True,
            timeout=10,
            handler=_desktop_notify,
        ),
        "context.snapshot": Capability(
            id="context.snapshot",
            summary="Read privacy-bounded desktop context",
            risk="low",
            privilege="unprivileged",
            requires_engagement=False,
            requires_approval=False,
            live_mode=False,
            audit=True,
            timeout=10,
            handler=_context_snapshot,
        ),
    }


def describe(capabilities: dict[str, Capability]) -> list[dict[str, Any]]:
    return [
        {
            "id": item.id,
            "summary": item.summary,
            "risk": item.risk,
            "privilege": item.privilege,
            "requires_engagement": item.requires_engagement,
            "requires_approval": item.requires_approval,
            "live_mode": item.live_mode,
            "audit": item.audit,
            "timeout_seconds": item.timeout,
        }
        for item in sorted(capabilities.values(), key=lambda entry: entry.id)
    ]
