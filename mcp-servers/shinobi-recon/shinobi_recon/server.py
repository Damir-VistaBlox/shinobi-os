"""shinobi-recon: an MCP server that lets an agent run a curated set of Kali
recon tools, gated by the active engagement's scope file.

Design rules for every tool in this file:
  1. Parameters are structured (target + an enum/closed set of options) —
     never a raw command string from the model.
  2. Call require_in_scope(target) before building any subprocess argv.
  3. Always call log_call(), on both the allowed and refused paths.
  4. Build argv as a list; never shell=True, never string-format model input
     into a shell command.
"""
from __future__ import annotations

import subprocess
from typing import Literal

from mcp.server.fastmcp import FastMCP

from .scope import ScopeError, current_engagement, log_call, require_in_scope

mcp = FastMCP("shinobi-recon")

_NMAP_PROFILES: dict[str, list[str]] = {
    "quick": ["-T4", "-F"],
    "full": ["-T4", "-p-"],
    "service": ["-T4", "-sV", "-sC"],
    "udp_top20": ["-T4", "-sU", "--top-ports", "20"],
}

_SCAN_TIMEOUT_S = 900


@mcp.tool()
def nmap_scan(
    target: str,
    profile: Literal["quick", "full", "service", "udp_top20"] = "quick",
) -> str:
    """Run an nmap scan against a single host that is authorized in the
    active engagement's scope.yaml. Refuses out-of-scope or malformed
    targets. Every call — allowed or refused — is written to the
    engagement's log.jsonl.

    Profiles:
      quick     -T4 -F              (fast, top 100 ports)
      full      -T4 -p-             (all 65535 ports, slow)
      service   -T4 -sV -sC         (service/version detection + default scripts)
      udp_top20 -T4 -sU --top-ports 20
    """
    flags = _NMAP_PROFILES[profile]
    argv = ["nmap", *flags, target]

    # Resolve the engagement first so refusals caused by an invalid window or
    # an out-of-scope target are recorded in that engagement's audit log too.
    # (A missing engagement has nowhere safe to write, so log_call falls back
    # to stderr for that particular refusal.)
    try:
        engagement = current_engagement()
    except ScopeError:
        engagement = None

    try:
        engagement = require_in_scope(target)
    except ScopeError as e:
        log_call(engagement, "nmap_scan", target, argv, "refused", str(e))
        raise

    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=_SCAN_TIMEOUT_S,
            check=False,
        )
        output = proc.stdout + ("\n" + proc.stderr if proc.stderr else "")
        log_call(engagement, "nmap_scan", target, argv, "allowed", output)
        return output
    except subprocess.TimeoutExpired:
        detail = f"timed out after {_SCAN_TIMEOUT_S}s"
        log_call(engagement, "nmap_scan", target, argv, "allowed", detail)
        return f"nmap_scan: {detail}"
    except OSError as e:
        detail = f"could not start nmap: {e}"
        log_call(engagement, "nmap_scan", target, argv, "allowed", detail)
        return f"nmap_scan: {detail}"


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
