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
import stat
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path

import yaml

_HOSTNAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")

# Must stay in step with validate_name() in bin/shinobi-engagement.
_ENGAGEMENT_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


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


def _engagements_root() -> Path:
    """Resolve the directory that holds all engagements.

    Mirrors shinobi_engagements_dir() in bin/_shinobi-common.sh. The
    SHINOBI_ENGAGEMENTS_DIR override exists so the packaged install can keep
    engagements beside the binaries; it names a *root*, not an engagement.
    """
    root = os.environ.get("SHINOBI_ENGAGEMENTS_DIR", "").strip()
    if not root:
        base = os.environ.get("XDG_DATA_HOME", "").strip() or str(Path.home() / ".local" / "share")
        root = str(Path(base) / "shinobi" / "engagements")
    return Path(root).expanduser()


def current_engagement() -> Engagement:
    """Locate the active engagement by name inside the engagements root.

    SHINOBI_ENGAGEMENT_DIR is deliberately not consulted. It is an ordinary
    environment variable, so anything able to launch this process could point
    the gate at a scope file it authored itself, and the gate would then
    authorize exactly what that file said -- which is the one outcome the
    gate exists to make impossible. The engagement is found by name under the
    engagements root instead, and the result must be a real directory sitting
    directly inside that root.
    """
    name = os.environ.get("SHINOBI_ENGAGEMENT", "").strip()
    if not name:
        raise ScopeError(
            "No active engagement (SHINOBI_ENGAGEMENT not set). "
            "Launch this server via `shinobi agent` after `shinobi engagement use <name>`."
        )
    if not _ENGAGEMENT_NAME_RE.fullmatch(name):
        raise ScopeError(f"Refusing malformed engagement name {name!r}")

    root = _engagements_root()
    candidate = root / name

    # A symlinked engagement directory would put the scope file outside the
    # root, so it is refused rather than followed.
    if candidate.is_symlink():
        raise ScopeError(f"Refusing symlinked engagement directory {candidate}")

    try:
        resolved_root = root.resolve(strict=True)
    except OSError as exc:
        raise ScopeError(f"Engagements root {root} is unusable: {exc}") from exc

    resolved = candidate.resolve()
    if resolved.parent != resolved_root:
        raise ScopeError(
            f"Engagement directory for {name!r} resolves to {resolved}, which is "
            f"outside the engagements root {resolved_root}. Refusing."
        )
    if not resolved.is_dir():
        raise ScopeError(f"No engagement directory at {resolved}")
    return Engagement(name=name, dir=resolved)


def _load_scope(engagement: Engagement) -> dict:
    """Load and validate the engagement's scope file.

    Every failure mode here raises ScopeError, never a bare parser or
    attribute error. That matters for more than tidiness: the callers only
    catch ScopeError, so a yaml.ParserError or an AttributeError escaping
    this function skips the audit log entirely. A hand-edited or truncated
    scope.yaml would then refuse every call while leaving no record that it
    did, which is the worst possible failure mode for an audit trail.
    """
    path = engagement.scope_file
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise ScopeError(f"No scope file at {path}") from exc
    except OSError as exc:
        raise ScopeError(f"Cannot read scope file {path}: {exc}") from exc

    # The scope file is the authorization itself, so it has to be a plain file
    # owned by whoever is running the tools. A symlink would let it point
    # somewhere else; a world- or group-writable file could have been edited
    # by another user, which means the targets in it are not trustworthy.
    if not stat.S_ISREG(info.st_mode):
        raise ScopeError(f"Refusing scope file {path}: not a regular file.")
    if info.st_mode & 0o022:
        raise ScopeError(
            f"Refusing scope file {path}: writable by group or other "
            f"(mode {stat.filemode(info.st_mode)}). Run "
            f"'chmod go-w {path}' to fix."
        )

    try:
        text = path.read_text()
    except OSError as exc:
        raise ScopeError(f"Cannot read scope file {path}: {exc}") from exc

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ScopeError(
            f"Scope file {path} is not valid YAML: {exc}. Refusing."
        ) from exc

    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise ScopeError(
            f"Scope file {path} must contain a mapping at the top "
            f"level, got {type(data).__name__}. Refusing."
        )
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


def log_call(
    engagement: Engagement | None,
    tool: str,
    target: str,
    args: list[str],
    verdict: str,
    detail: str = "",
    *,
    phase: str = "result",
    call_id: str | None = None,
) -> str:
    """Append one audit record and return its call id.

    verdict: 'allowed' -- the target was authorized and answered
             'refused' -- policy stopped the call; the target was not reached
             'error'   -- policy allowed it, the network did not deliver
    phase:   'intent'  -- written before the tool runs
             'result'  -- written after it finishes, with the verdict

    Every tool writes an 'intent' record *before* it executes anything and a
    'result' record afterwards. The intent record is what makes the log
    fail-closed: if the tool is killed, crashes the session, or the machine
    loses power mid-scan, the intent record is the only surviving evidence
    that the call was attempted. Logging only the outcome meant an
    interrupted call left no trace at all, which is indistinguishable from
    the call never having happened.

    The two records share a call_id so an outcome can be tied back to the
    attempt that produced it.
    """
    if call_id is None:
        call_id = uuid.uuid4().hex[:16]
    entry = {
        "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "call_id": call_id,
        "phase": phase,
        "tool": tool,
        "target": target,
        "args": args,
        "verdict": verdict,
        "detail": detail[:2000],
    }
    if engagement is None:
        # Refused before we could even resolve an engagement (e.g. env not
        # set) — nowhere safe to log to, so this must still reach stderr.
        #
        # stderr specifically: this server speaks MCP over stdio, so stdout
        # is the JSON-RPC transport. A bare text line on stdout corrupts the
        # protocol stream and takes down the session.
        print(f"shinobi-recon: {json.dumps(entry)}", file=sys.stderr, flush=True)
        return call_id
    with engagement.log_file.open("a") as f:
        f.write(json.dumps(entry) + "\n")
        f.flush()
        # The intent record has to survive the tool running, including a hard
        # kill, so it cannot sit in the page cache.
        os.fsync(f.fileno())
    return call_id
