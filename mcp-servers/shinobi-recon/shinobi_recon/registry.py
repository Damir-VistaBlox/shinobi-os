"""tools/*.toml as the single source of truth for recon tool policy.

These manifests used to be decorative: `shinobi tool inspect` printed them,
and nothing else read them. The MCP tools in server.py hardcoded their own
timeouts and never consulted `requires_approval`, so a manifest could claim a
tool was approval-gated while the tool ran freely.

They are authoritative now. Every tool exposed over MCP must have a valid
manifest, and the policy fields are read from it rather than restated in
code. A tool whose manifest is missing or malformed is not exposed at all --
failing closed is the only safe direction for a file that decides what an
agent may run.

The control plane keeps its own capability registry; the two describe
different things (recon tools vs. control-plane verbs) and ship as separate
packages, so they are not merged here.
"""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path

RISKS = frozenset({"passive", "active", "intrusive"})

# Every manifest must set all of these, and set them to one of these values.
# An unknown risk or a missing field is a manifest error, not a default.
# `binary` is deliberately not required: a tool that runs in-process (http_headers
# uses urllib, spawning nothing) has no binary, and inventing a value like
# "python3" for it puts a claim in the manifest that nothing checks and nobody
# can verify. A tool that *does* spawn must declare one -- server.py raises if
# it tries to build argv for a manifest with no binary.
_REQUIRED_FIELDS = (
    "id",
    "name",
    "category",
    "risk",
    "requires_scope",
    "requires_approval",
    "supports_live",
    "timeout_seconds",
    "mcp_tool",
)

# Valid to omit, valid to set.
_OPTIONAL_FIELDS = ("binary",)


class RegistryError(RuntimeError):
    """Raised when the tool registry is missing, malformed, or inconsistent."""


@dataclass(frozen=True)
class ToolManifest:
    id: str
    name: str
    binary: str | None
    category: str
    risk: str
    requires_scope: bool
    requires_approval: bool
    supports_live: bool
    timeout_seconds: int
    mcp_tool: str
    source: Path

    @classmethod
    def parse(cls, data: object, source: Path) -> "ToolManifest":
        if not isinstance(data, dict):
            raise RegistryError(f"{source}: manifest must be a table")

        missing = [field for field in _REQUIRED_FIELDS if field not in data]
        if missing:
            raise RegistryError(f"{source}: missing required field(s): {', '.join(missing)}")
        unknown = sorted(set(data) - set(_REQUIRED_FIELDS) - set(_OPTIONAL_FIELDS))
        if unknown:
            # A typo'd policy field would otherwise read as "not set" and
            # silently drop a restriction.
            raise RegistryError(f"{source}: unknown field(s): {', '.join(unknown)}")

        for field in ("id", "name", "category", "mcp_tool"):
            value = data[field]
            if not isinstance(value, str) or not value.strip():
                raise RegistryError(f"{source}: {field} must be a non-empty string")
        if "binary" in _OPTIONAL_FIELDS and "binary" in data and (
            not isinstance(data["binary"], str) or not data["binary"].strip()
        ):
            raise RegistryError(f"{source}: binary must be a non-empty string when present")
        for field in ("requires_scope", "requires_approval", "supports_live"):
            if not isinstance(data[field], bool):
                raise RegistryError(f"{source}: {field} must be a boolean")
        if data["risk"] not in RISKS:
            raise RegistryError(f"{source}: risk must be one of {sorted(RISKS)}, got {data['risk']!r}")

        timeout = data["timeout_seconds"]
        if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 3600:
            raise RegistryError(f"{source}: timeout_seconds must be an integer in 1..3600, got {timeout!r}")

        return cls(
            id=data["id"],
            name=data["name"],
            binary=data.get("binary"),
            category=data["category"],
            risk=data["risk"],
            requires_scope=data["requires_scope"],
            requires_approval=data["requires_approval"],
            supports_live=data["supports_live"],
            timeout_seconds=timeout,
            mcp_tool=data["mcp_tool"],
            source=source,
        )


def tools_dir() -> Path:
    """Locate the manifest directory.

    Order: explicit override, the site-installed location, the copy shipped
    inside the wheel, then the source tree, so the same code works installed
    from a package, from an ISO, and in a checkout.

    The site-installed location comes before the packaged one so an operator
    editing /usr/share/shinobi/tools keeps doing so. The packaged copy is what
    makes a plain `pip install shinobi-recon` work at all: without it the
    wheel carries the code that enforces the policy but not the policy, and the
    registry fails closed with "tool manifest directory not found" pointing at
    site-packages.
    """
    override = os.environ.get("SHINOBI_TOOLS_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    packaged = Path("/usr/share/shinobi/tools")
    if packaged.is_dir():
        return packaged
    inside_package = Path(__file__).resolve().parent / "tools"
    if inside_package.is_dir():
        return inside_package
    return Path(__file__).resolve().parents[3] / "tools"


def load_all(directory: str | os.PathLike[str] | None = None) -> dict[str, ToolManifest]:
    """Load every manifest, keyed by MCP tool name.

    Raises RegistryError if any manifest is invalid, or if two manifests claim
    the same MCP tool. A registry that loads partially is worse than one that
    refuses to load, because the caller cannot tell which tools are governed.
    """
    root = Path(directory) if directory is not None else tools_dir()
    if not root.is_dir():
        raise RegistryError(f"tool manifest directory not found: {root}")

    manifests: dict[str, ToolManifest] = {}
    for path in sorted(root.glob("*.toml")):
        try:
            with path.open("rb") as handle:
                data = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise RegistryError(f"{path}: cannot read manifest ({exc})") from exc
        manifest = ToolManifest.parse(data, path)
        if manifest.mcp_tool in manifests:
            other = manifests[manifest.mcp_tool].source
            raise RegistryError(
                f"{path}: mcp_tool {manifest.mcp_tool!r} is already claimed by {other}"
            )
        manifests[manifest.mcp_tool] = manifest
    return manifests


def require(mcp_tool: str, directory: str | os.PathLike[str] | None = None) -> ToolManifest:
    """Return the manifest for an MCP tool, or raise.

    Callers use this at import time so a tool with no valid manifest cannot be
    exposed: the server then fails to start rather than serving an
    ungoverned capability.
    """
    manifests = load_all(directory)
    try:
        return manifests[mcp_tool]
    except KeyError:
        raise RegistryError(
            f"no tool manifest governs MCP tool {mcp_tool!r} in {directory or tools_dir()}"
        ) from None
