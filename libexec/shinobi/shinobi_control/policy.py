"""Minimal fail-closed trust policy evaluator."""
from __future__ import annotations

import os
from pathlib import Path

from .registry import Capability

PROFILES = {"observer", "analyst", "operator", "administrator", "emergency"}


def profile_path() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/profile"


def current_profile() -> str:
    try:
        value = profile_path().read_text(encoding="utf-8").strip()
    except OSError:
        value = "observer"
    return value if value in PROFILES else "observer"


def allowed(capability: Capability, profile: str | None = None) -> tuple[bool, str]:
    profile = profile or current_profile()
    if profile not in PROFILES:
        return False, "unknown trust profile"
    if capability.privilege != "unprivileged" and profile not in {"operator", "administrator", "emergency"}:
        return False, f"profile '{profile}' cannot use privileged capability"
    if capability.risk == "high" and profile != "emergency":
        return False, "high-risk capability requires emergency profile"
    if capability.requires_approval:
        return False, "explicit approval required"
    return True, "allowed"
