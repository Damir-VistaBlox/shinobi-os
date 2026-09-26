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


def current_engagement() -> str:
    """The active engagement name, or "" when none is selected.

    Reads the state file the CLI writes rather than the environment: the
    daemon is not launched per-engagement, so there is no engagement in its
    environment to read.
    """
    path = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/current-engagement"
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def is_live_mode() -> bool:
    """True when running from the live image rather than an installed system."""
    return Path("/run/live/medium/live/filesystem.squashfs").exists()


def allowed(
    capability: Capability,
    profile: str | None = None,
    *,
    arguments: dict | None = None,
    engagement: str | None = None,
    live: bool | None = None,
    approval_id: str | None = None,
) -> tuple[bool, str]:
    """Decide whether a capability may run. Returns (allowed, reason).

    Every field a Capability declares is enforced here. `requires_engagement`
    and `live_mode` were previously declared on the dataclass and read by
    nothing, so a capability could claim to need an engagement and would run
    happily with none.

    `arguments` are bound into any approval, so an approval granted for one
    call cannot be replayed for a different set of arguments under the same
    capability.
    """
    profile = profile or current_profile()
    if profile not in PROFILES:
        return False, "unknown trust profile"

    engagement = current_engagement() if engagement is None else engagement
    live = is_live_mode() if live is None else live

    if capability.privilege != "unprivileged" and profile not in {"operator", "administrator", "emergency"}:
        return False, f"profile '{profile}' cannot use privileged capability"

    if capability.risk == "high" and profile != "emergency":
        return False, "high-risk capability requires emergency profile"

    if capability.requires_engagement and not engagement:
        return False, "capability requires an active engagement"

    if capability.live_mode and not live:
        return False, "capability is only available on the live image"

    if capability.requires_approval:
        if not approval_id:
            return False, "explicit approval required"
        # The approval is claimed here, atomically, so two concurrent requests
        # cannot both spend the same approval. A failure is a denial.
        from .approval import ApprovalError, consume

        try:
            consume(
                approval_id,
                capability=capability.id,
                arguments=arguments or {},
                profile=profile,
            )
        except (ApprovalError, FileNotFoundError, ValueError) as exc:
            return False, f"approval rejected: {exc}"

    return True, "allowed"
