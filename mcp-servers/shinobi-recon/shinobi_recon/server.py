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

from typing import Literal

from mcp.server.fastmcp import FastMCP

from . import http
from .process import run
from .scope import ScopeError, current_engagement, log_call, require_in_scope

mcp = FastMCP("shinobi-recon")

_NMAP_PROFILES: dict[str, list[str]] = {
    "quick": ["-T4", "-F"],
    "full": ["-T4", "-p-"],
    "service": ["-T4", "-sV", "-sC"],
    "udp_top20": ["-T4", "-sU", "--top-ports", "20"],
}

_SCAN_TIMEOUT_S = 900
_PASSIVE_TIMEOUT_S = 30


def _engagement_for_call():
    try:
        return current_engagement()
    except ScopeError:
        return None


def _authorized(tool: str, target: str, argv: list[str]):
    engagement = _engagement_for_call()
    try:
        return require_in_scope(target)
    except ScopeError as exc:
        log_call(engagement, tool, target, argv, "refused", str(exc))
        raise


def _redirect_guard(host: str) -> None:
    """Adapt a scope refusal onto the http module's refusal contract.

    http.fetch_headers does not import scope, so the authorizer it calls is
    responsible for raising http.RedirectRefused. Keeping the translation
    here means the "redirects are re-scoped" rule lives in exactly one place.
    """
    try:
        require_in_scope(host)
    except ScopeError as exc:
        raise http.RedirectRefused(f"out-of-scope redirect target {host!r}: {exc}") from exc


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
    engagement = _authorized("nmap_scan", target, argv)

    result = run(argv, timeout=_SCAN_TIMEOUT_S)
    output = result.stdout + ("\n" + result.stderr if result.stderr else "")
    if result.timed_out:
        output = f"nmap_scan: timed out after {_SCAN_TIMEOUT_S}s\n{output}".rstrip()
    log_call(engagement, "nmap_scan", target, argv, "allowed", output)
    return output or f"nmap_scan: exited with status {result.returncode}"


@mcp.tool()
def dns_lookup(target: str) -> str:
    """Resolve an in-scope hostname or address using the local resolver."""
    argv = ["getent", "ahosts", target]
    engagement = _authorized("dns_lookup", target, argv)
    result = run(argv, timeout=_PASSIVE_TIMEOUT_S)
    output = result.stdout + ("\n" + result.stderr if result.stderr else "")
    if result.timed_out:
        output = f"dns_lookup: timed out after {_PASSIVE_TIMEOUT_S}s\n{output}".rstrip()
    log_call(engagement, "dns_lookup", target, argv, "allowed", output)
    return output or f"dns_lookup: resolver exited with status {result.returncode}"


@mcp.tool()
def whatweb_scan(target: str) -> str:
    """Run passive WhatWeb fingerprinting on an in-scope host."""
    argv = ["whatweb", "--no-errors", "--color=never", f"https://{target}"]
    engagement = _authorized("whatweb_scan", target, argv)
    result = run(argv, timeout=_PASSIVE_TIMEOUT_S)
    output = result.stdout + ("\n" + result.stderr if result.stderr else "")
    if result.timed_out:
        output = f"whatweb_scan: timed out after {_PASSIVE_TIMEOUT_S}s\n{output}".rstrip()
    log_call(engagement, "whatweb_scan", target, argv, "allowed", output)
    return output or f"whatweb_scan: exited with status {result.returncode}"


@mcp.tool()
def http_headers(
    target: str,
    scheme: Literal["http", "https"] = "https",
    port: int | None = None,
) -> str:
    """Fetch response headers from an in-scope host without crawling it.

    Redirects are followed, but every hop is re-checked against the same
    scope policy as the original target. A redirect onto an out-of-scope
    host is refused and the refusal is recorded in the audit log.
    """
    http.validate_port(port)
    host = target
    url = http.build_url(scheme, host, port)
    engagement = _authorized("http_headers", host, ["HEAD", url])
    result = http.fetch_headers(url, authorize=_redirect_guard, timeout=_PASSIVE_TIMEOUT_S)
    log_call(engagement, "http_headers", host, ["HEAD", url], result.verdict, result.output)
    return result.output


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
