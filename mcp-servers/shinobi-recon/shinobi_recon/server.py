"""shinobi-recon: an MCP server that lets an agent run a curated set of Kali
recon tools, gated by the active engagement's scope file.

Design rules for every tool in this file:
  1. Parameters are structured (target + an enum/closed set of options) —
     never a raw command string from the model.
  2. Call require_in_scope(target) before building any subprocess argv.
  3. Always call log_call(), on both the allowed and refused paths.
  4. Build argv as a list; never shell=True, never string-format model input
     into a shell command.
  5. Take the tool's binary, timeout and approval requirement from its
     tools/*.toml manifest, not from a constant in this file.
  6. Reject unknown arguments rather than running on defaults. mcp silently
     drops arguments a tool does not declare, which is not a no-op when the
     argument selects behaviour -- see argcheck.py.

Rule 5 exists because these used to be restated here and drifted: a manifest
could declare a tool approval-gated while this file ran it freely. The
manifests are now the only place that policy is written down, and a tool with
no valid manifest stops the server from starting.

Rule 6 exists for the same reason. An end-to-end test in this repo asked for
nmap_scan(preset="quick") where the tool declares profile, and passed, because
quick is also the default. The argument was dropped, the test asserted the
value it had already been given, and the mistake was invisible. A model makes
that class of error constantly, and the result is a tool reporting success for
a scan it did not run.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Literal

from mcp.server.fastmcp import FastMCP

from . import argcheck, httpclient, registry
from .registry import RegistryError
from .process import run
from .scope import ScopeError, current_engagement, log_call, require_in_scope

mcp = FastMCP("shinobi-recon")

_NMAP_PROFILES: dict[str, list[str]] = {
    "quick": ["-T4", "-F"],
    "full": ["-T4", "-p-"],
    "service": ["-T4", "-sV", "-sC"],
    "udp_top20": ["-T4", "-sU", "--top-ports", "20"],
}

# Resolved at import time, so a missing or malformed manifest prevents the
# server from starting rather than silently serving an ungoverned tool.
_NMAP = registry.require("nmap_scan")
_DNS = registry.require("dns_lookup")
_WHATWEB = registry.require("whatweb_scan")
_HTTP = registry.require("http_headers")


def _engagement_for_call():
    try:
        return current_engagement()
    except ScopeError:
        return None


def _authorized(tool: str, target: str, argv: list[str]):
    """Check scope and open an audit record for the call.

    Returns (engagement, call_id). The 'intent' record is written here, before
    the tool runs, so an interrupted or killed call still leaves evidence that
    it was attempted. The caller closes the record with _finish().
    """
    engagement = _engagement_for_call()
    try:
        require_in_scope(target)
    except ScopeError as exc:
        log_call(engagement, tool, target, argv, "refused", str(exc), phase="result")
        raise
    call_id = log_call(engagement, tool, target, argv, "pending", phase="intent")
    return engagement, call_id


def _finish(engagement, call_id: str, tool: str, target: str, argv: list[str], verdict: str, detail: str = "") -> None:
    log_call(engagement, tool, target, argv, verdict, detail, phase="result", call_id=call_id)


def _binary(manifest) -> str:
    """The external binary for a tool that spawns a subprocess.

    A manifest may legitimately name no binary, for a tool that runs
    in-process. If such a tool is ever wired up to spawn something, this
    raises rather than quietly building an argv with no program in it.
    """
    if not manifest.binary:
        raise RegistryError(
            f"tool {manifest.id} declares no binary, so it cannot be run as a subprocess"
        )
    return manifest.binary


def _approval_cli() -> str | None:
    """Locate the approval CLI.

    Approval state is shared with the control plane, and the claim logic --
    argument binding, expiry, single use -- lives there in one place. This
    server shells out to it rather than reimplementing those checks, because
    two copies of a security rule eventually disagree and the laxer one wins.

    There is deliberately no environment override. This helper is the thing that
    decides whether a tool call was approved, so a variable that could redirect
    it would hand that decision to whoever can set this process's environment --
    which is a weaker guarantee than the approval it is meant to enforce. The
    same reasoning keeps the provider client from relaxing certificate checking.
    """
    found = shutil.which("shinobi-approval")
    if found:
        return found
    sibling = Path(__file__).resolve().parents[3] / "bin" / "shinobi-approval"
    return str(sibling) if sibling.is_file() else None


def _require_approval(manifest, arguments: dict, approval_id: str | None, tool: str) -> None:
    """Enforce the manifest's requires_approval, raising ScopeError to refuse.

    An approval authorizes one exact call, so the arguments are bound into the
    request and re-checked on the way through. Reusing an approval for a
    different target is refused, not silently allowed.
    """
    if not manifest.requires_approval:
        return
    cli = _approval_cli()
    if cli is None:
        # Fail closed: an approval-gated tool must not run just because the
        # approval helper is missing.
        raise ScopeError(
            f"{tool} requires explicit approval, but the approval helper "
            f"(shinobi-approval) is not available; refusing."
        )

    payload = json.dumps(arguments, sort_keys=True)
    if not approval_id:
        requested = subprocess.run(
            [cli, "request", "--capability", manifest.id, "--args-json", payload,
             "--reason", f"{tool} requested by agent"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        if requested.returncode != 0:
            raise ScopeError(f"could not request approval: {requested.stderr.strip()}")
        try:
            new_id = json.loads(requested.stdout)["approval_id"]
        except (json.JSONDecodeError, KeyError) as exc:
            raise ScopeError("approval request returned no usable id") from exc
        raise ScopeError(
            f"{tool} requires explicit human approval. Requested approval "
            f"{new_id} for {payload}. Have an operator run "
            f"'shinobi approval approve {new_id}', then retry with "
            f"approval_id={new_id}."
        )

    claimed = subprocess.run(
        [cli, "consume", approval_id, "--capability", manifest.id, "--args-json", payload],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if claimed.returncode != 0:
        raise ScopeError(f"approval {approval_id} rejected: {claimed.stderr.strip() or 'unknown reason'}")


def _redirect_guard(host: str) -> None:
    """Adapt a scope refusal onto the http module's refusal contract.

    httpclient.fetch_headers does not import scope, so the authorizer it calls is
    responsible for raising httpclient.RedirectRefused. Keeping the translation
    here means the "redirects are re-scoped" rule lives in exactly one place.
    """
    try:
        require_in_scope(host)
    except ScopeError as exc:
        raise httpclient.RedirectRefused(f"out-of-scope redirect target {host!r}: {exc}") from exc


@mcp.tool()
def nmap_scan(
    target: str,
    profile: Literal["quick", "full", "service", "udp_top20"] = "quick",
    approval_id: str | None = None,
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

    tools/nmap-scan.toml marks this tool as requiring approval, so it runs only
    against an approval a human granted for this exact target and profile. Call
    it without approval_id to have a request created for an operator.
    """
    flags = _NMAP_PROFILES[profile]
    argv = [_binary(_NMAP), *flags, target]

    # Resolve the engagement first so refusals caused by an invalid window or
    # an out-of-scope target are recorded in that engagement's audit log too.
    # (A missing engagement has nowhere safe to write, so log_call falls back
    # to stderr for that particular refusal.)
    engagement, call_id = _authorized("nmap_scan", target, argv)
    try:
        _require_approval(_NMAP, {"target": target, "profile": profile}, approval_id, "nmap_scan")
    except ScopeError as exc:
        _finish(engagement, call_id, "nmap_scan", target, argv, "refused", str(exc))
        raise

    result = run(argv, timeout=_NMAP.timeout_seconds)
    output = result.stdout + ("\n" + result.stderr if result.stderr else "")
    if result.timed_out:
        output = f"nmap_scan: timed out after {_NMAP.timeout_seconds}s\n{output}".rstrip()
    _finish(engagement, call_id, "nmap_scan", target, argv, "allowed", output)
    return output or f"nmap_scan: exited with status {result.returncode}"


@mcp.tool()
def dns_lookup(target: str) -> str:
    """Resolve an in-scope hostname or address using the local resolver."""
    argv = [_binary(_DNS), "ahosts", target]
    engagement, call_id = _authorized("dns_lookup", target, argv)
    result = run(argv, timeout=_DNS.timeout_seconds)
    output = result.stdout + ("\n" + result.stderr if result.stderr else "")
    if result.timed_out:
        output = f"dns_lookup: timed out after {_DNS.timeout_seconds}s\n{output}".rstrip()
    _finish(engagement, call_id, "dns_lookup", target, argv, "allowed", output)
    return output or f"dns_lookup: resolver exited with status {result.returncode}"


@mcp.tool()
def whatweb_scan(target: str) -> str:
    """Run passive WhatWeb fingerprinting on an in-scope host."""
    argv = [_binary(_WHATWEB), "--no-errors", "--color=never", f"https://{target}"]
    engagement, call_id = _authorized("whatweb_scan", target, argv)
    result = run(argv, timeout=_WHATWEB.timeout_seconds)
    output = result.stdout + ("\n" + result.stderr if result.stderr else "")
    if result.timed_out:
        output = f"whatweb_scan: timed out after {_WHATWEB.timeout_seconds}s\n{output}".rstrip()
    _finish(engagement, call_id, "whatweb_scan", target, argv, "allowed", output)
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
    httpclient.validate_port(port)
    host = target
    url = httpclient.build_url(scheme, host, port)
    engagement, call_id = _authorized("http_headers", host, ["HEAD", url])
    result = httpclient.fetch_headers(url, authorize=_redirect_guard, timeout=_HTTP.timeout_seconds)
    _finish(engagement, call_id, "http_headers", host, ["HEAD", url], result.verdict, result.output)
    return result.output


def _log_unknown_arguments(tool: str, arguments: dict, unknown: list[str], detail: str) -> None:
    """Record a call refused for unknown arguments, then let it be refused.

    A refusal with no audit record breaks the invariant the rest of this file
    is built on -- every call, allowed or refused, reaches the engagement log
    (DESIGN.md). That holds for the scope gate and the approval gate; a
    misspelled argument has to hold for it too, or the one class of call the
    model makes most often is the one class nobody can account for afterwards.

    What goes in `args` is the rejected key *names*, not their values. The
    values are model-supplied text that failed validation, so there is no
    reason to persist them; the names are what an operator needs to see, and
    they are bounded by the schema's shape. A `target` is carried over when the
    client spelled it correctly, because the operator is trying to work out
    which host the agent meant, and "<unset>" is the honest answer when even
    that was misspelled.
    """
    engagement = _engagement_for_call()
    target = arguments.get("target")
    log_call(
        engagement,
        tool,
        target if isinstance(target, str) and target else "<unset>",
        unknown,
        "refused",
        detail,
        phase="result",
    )


def _install_argument_guard() -> None:
    """Refuse unknown tool arguments before the tool manager drops them.

    Wraps ToolManager.call_tool rather than each tool, because that is the only
    point that still holds the client's raw argument dict -- see argcheck.py for
    why the extras are unrecoverable by the time a tool body runs. The tool is
    resolved at call time, so this stays correct for tools registered after this
    runs, and it is installed once instead of being repeated per tool.

    The raise is a ScopeError so it travels the same path as every other
    refusal: the lowlevel server turns it into a normal CallToolResult with
    isError=True, which is what callers already handle for a refused scope or
    a rejected approval.

    The introspection it depends on is private API in two places -- the
    tool manager on FastMCP, and fn_metadata.arg_model on the tool. A mcp
    upgrade that moves either would otherwise leave the guard silently
    inert, which is the worst possible outcome: the server would go on
    dropping unknown arguments exactly as before, and nothing would say so.
    So the paths are verified against every registered tool before the guard
    is accepted, and a server that cannot introspect its own tools refuses to
    start rather than serve them unguarded. The same reasoning as a tool with
    no valid manifest, applied to the mechanism that enforces the manifests.
    """
    manager = getattr(mcp, "_tool_manager", None)
    if manager is None or not callable(getattr(manager, "call_tool", None)):
        raise RegistryError(
            "cannot install the argument guard: this mcp version exposes no "
            "FastMCP._tool_manager with a callable call_tool. Refusing to serve "
            "tools, because unknown arguments would be silently dropped again. "
            "Pin mcp<2 and re-check argcheck.py against the installed version."
        )

    for tool in manager.list_tools():
        arg_model = getattr(getattr(tool, "fn_metadata", None), "arg_model", None)
        if arg_model is None:
            raise RegistryError(
                f"cannot install the argument guard: {tool.name} exposes no "
                "fn_metadata.arg_model, so its parameter names cannot be read. "
                "Refusing to serve tools rather than dropping unknown arguments."
            )

    original = manager.call_tool

    async def guarded(name, arguments, context=None, convert_result=False):
        requested = arguments or {}
        tool = manager.get_tool(name)
        if tool is not None:
            accepted = argcheck.accepted_arguments(tool.fn_metadata.arg_model)
            unknown = argcheck.unknown_arguments(requested, accepted)
            if unknown:
                detail = argcheck.describe_unknown(name, unknown, accepted)
                _log_unknown_arguments(name, requested, unknown, detail)
                raise ScopeError(detail)
        return await original(name, requested, context=context, convert_result=convert_result)

    manager.call_tool = guarded
    if manager.call_tool is not guarded:
        raise RegistryError("the argument guard did not install; refusing to serve tools.")



_install_argument_guard()


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
