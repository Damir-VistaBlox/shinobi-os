#!/usr/bin/env bash
# Tests for the tools/*.toml registry that now governs recon tool policy.
#
# The manifests used to be decorative -- printed by `shinobi tool inspect` and
# read by nothing -- while server.py hardcoded its own timeouts and ran
# approval-gated tools freely. These tests cover the parser's refusals, and
# the anti-drift properties: that every MCP tool has a manifest, that the
# manifest values are the ones server.py actually uses, and that the old
# hardcoded constants are gone.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT/mcp-servers/shinobi-recon${PYTHONPATH:+:$PYTHONPATH}"
export ROOT

python3 - <<'PY'
import os
import re
import sys
import tempfile
from pathlib import Path

from shinobi_recon.registry import RegistryError, ToolManifest, load_all, require, tools_dir

repo = Path(os.environ["ROOT"]).resolve()
failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        failures.append(message)


def refuses(manifest_text, label, directory=None):
    """Write one manifest into a temp dir and expect load_all to refuse it."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "bad.toml").write_text(manifest_text, encoding="utf-8")
        try:
            load_all(root)
        except RegistryError as exc:
            check(True, f"refuses {label} ({exc})")
        else:
            check(False, f"refuses {label} (loaded it without complaint)")


VALID = """
id = "tool.test"
name = "Test"
binary = "true"
category = "recon"
risk = "active"
requires_scope = true
requires_approval = false
supports_live = true
timeout_seconds = 60
mcp_tool = "test_tool"
"""

print("== the shipped manifests ==")
manifests = load_all(repo / "tools")
check(len(manifests) == 4, f"four tool manifests load (got {len(manifests)}: {sorted(manifests)})")
for name, manifest in sorted(manifests.items()):
    check(manifest.mcp_tool == name, f"{manifest.source.name} maps to mcp_tool {name!r}")
    check(manifest.source.is_file(), f"{name} records the manifest it came from")

by_id = {m.id: m for m in manifests.values()}
check("tool.active.nmap" in by_id, "the nmap manifest is present under its stable id")
check(by_id["tool.active.nmap"].requires_approval, "nmap still declares that it needs approval")
check(by_id["tool.active.nmap"].timeout_seconds == 900, "nmap's timeout is 900s in the manifest")
check(
    not any(m.requires_approval for k, m in manifests.items() if k != "nmap_scan"),
    "nmap is the only approval-gated recon tool",
)

print("== every MCP tool in server.py is governed by a manifest ==")
server_src = (repo / "mcp-servers/shinobi-recon/shinobi_recon/server.py").read_text()
declared = set(re.findall(r'registry\.require\(\s*"([a-z_]+)"\s*\)', server_src))
check(declared == set(manifests), f"server.py requires exactly the manifested tools (got {sorted(declared)})")
for tool in sorted(declared):
    check(require(tool, repo / "tools").mcp_tool == tool, f"{tool} resolves through require()")

print("== server.py takes policy from the manifest, not from constants ==")
for gone in ("_SCAN_TIMEOUT_S", "_PASSIVE_TIMEOUT_S"):
    check(gone not in server_src, f"the hardcoded constant {gone} is gone")
check(".timeout_seconds" in server_src, "server.py reads timeouts from the manifests")
check("_NMAP.requires_approval" in server_src or "_require_approval(" in server_src, "server.py consults requires_approval")
for tool in ("_NMAP", "_DNS", "_WHATWEB"):
    check(f"_binary({tool})" in server_src, f"server.py takes the binary from {tool} via _binary()")
check("_binary(_HTTP)" not in server_src, "http_headers spawns nothing, so it names no binary")
check("_binary(" in server_src and "cannot be run as a subprocess" in server_src,
      "a spawning tool with no declared binary is refused at runtime")

print("== a tool that runs in-process declares no binary ==")
# http_headers uses urllib. Naming a binary for it (it used to say "python3")
# put an unverifiable claim in the policy file.
check(by_id["tool.passive.http_headers"].binary is None, "http_headers declares no binary")
for ident in ("tool.passive.dns_lookup", "tool.passive.whatweb", "tool.active.nmap"):
    check(by_id[ident].binary is not None, f"{ident} declares the binary it spawns")

print("== refusals: a policy file that cannot be understood ==")
refuses("", "an empty manifest")
refuses("this is not toml = = =", "malformed TOML")
refuses(VALID.replace('mcp_tool = "test_tool"\n', ""), "a manifest with no mcp_tool field")
refuses(VALID + 'requries_scope = true\n', "a typo'd policy field")
refuses(VALID.replace('requires_approval = false', 'requires_approval = "no"'), "a non-boolean flag")
refuses(VALID.replace('requires_scope = true', 'requires_scope = 1'), "an integer where a boolean belongs")
refuses(VALID.replace('risk = "active"', 'risk = "spicy"'), "an unknown risk level")
refuses(VALID.replace('timeout_seconds = 60', 'timeout_seconds = 0'), "a zero timeout")
refuses(VALID.replace('timeout_seconds = 60', 'timeout_seconds = 3601'), "a timeout over an hour")
refuses(VALID.replace('timeout_seconds = 60', 'timeout_seconds = 60.5'), "a fractional timeout")
refuses(VALID.replace('timeout_seconds = 60', 'timeout_seconds = true'), "a boolean timeout")
refuses(VALID.replace('timeout_seconds = 60', 'timeout_seconds = "60"'), "a string timeout")
refuses(VALID.replace('binary = "true"', 'binary = ""'), "an empty binary")
refuses(VALID.replace('binary = "true"', 'binary = 7'), "a non-string binary")
refuses(VALID.replace('name = "Test"', 'name = 7'), "a non-string name")
refuses(VALID + '\n[extra]\nkey = "value"\n', "a manifest with a stray table")
refuses('"just a string"', "a manifest that is not a table")

print("== refusals: structural ==")
missing = Path(tempfile.gettempdir()) / "shinobi-no-such-tools-dir-9d3f"
try:
    load_all(missing)
except RegistryError as exc:
    check(True, f"refuses a missing manifest directory ({exc})")
else:
    check(False, "refuses a missing manifest directory (returned empty)")

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "one.toml").write_text(VALID, encoding="utf-8")
    (root / "two.toml").write_text(VALID.replace('id = "tool.test"', 'id = "tool.other"'), encoding="utf-8")
    try:
        load_all(root)
    except RegistryError as exc:
        check("already claimed" in str(exc), f"refuses two manifests claiming one MCP tool ({exc})")
    else:
        check(False, "refuses two manifests claiming one MCP tool (loaded both)")

print("== an incomplete registry is not served ==")
# require() must raise rather than return a default, so server.py cannot start
# with an ungoverned tool.
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "only.toml").write_text(VALID, encoding="utf-8")
    check(require("test_tool", root).mcp_tool == "test_tool", "require() returns a present manifest")
    try:
        require("nmap_scan", root)
    except RegistryError as exc:
        check(True, f"require() raises for an unmanifested tool ({exc})")
    else:
        check(False, "require() raises for an unmanifested tool (returned something)")

print("== tools_dir() resolution ==")
check(isinstance(tools_dir(), Path), f"tools_dir() returns a path ({tools_dir()})")

print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print("tool-registry-test: FAIL")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)
print("tool-registry-test: PASS")
PY
