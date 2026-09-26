#!/usr/bin/env python3
"""End-to-end check of the real shinobi-recon MCP server.

Drives the actual server over stdio with the real mcp client, not the internals,
so this exercises the whole chain: manifest load at import, scope authorization,
the approval gate, subprocess dispatch and the audit trail.

nmap and whatweb are stubbed so the suite does not depend on either being
installed, and so the argv the manifest produced can be inspected. The stubs
record their arguments, which is how the manifest-declared binary and flags are
verified rather than assumed. dns_lookup and http_headers use the real getent
and curl.

Run directly, or via tests/test-mcp-e2e.sh which skips when the mcp package is
absent.
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PYTHON = sys.executable

failures: list[str] = []
passes = 0


def check(name: str, actual, expected) -> None:
    global passes
    if actual == expected:
        passes += 1
        print(f"  ok   {name}")
    else:
        failures.append(name)
        print(f"  FAIL {name}\n       expected: {expected!r}\n       actual:   {actual!r}")


def check_contains(name: str, haystack: str, needle: str) -> None:
    global passes
    if needle in haystack:
        passes += 1
        print(f"  ok   {name}")
    else:
        failures.append(name)
        print(f"  FAIL {name}\n       expected to contain: {needle!r}\n       actual: {haystack!r}")


def audit_records(engagement_dir: Path) -> list[dict]:
    log = engagement_dir / "log.jsonl"
    if not log.is_file():
        return []
    return [json.loads(line) for line in log.read_text().splitlines() if line.strip()]


async def main() -> int:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    work = Path(tempfile.mkdtemp())
    stub_bin = work / "bin"
    stub_bin.mkdir()
    for tool in ("nmap", "whatweb"):
        stub = stub_bin / tool
        stub.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$0" "$@" > "{work}/{tool}-argv"\n'
            f'echo "{tool} stub: $*" >> "{work}/{tool}-argv"\n'
            f'echo "{tool} stub output for $*"\n'
        )
        stub.chmod(0o755)

    engagements = work / "engagements"
    engagement = engagements / "e2e"
    engagement.mkdir(parents=True)
    today = date.today()
    (engagement / "scope.yaml").write_text(
        "client: e2e\n"
        "window:\n"
        f"  start: {(today - timedelta(days=1)).isoformat()}\n"
        f"  end: {(today + timedelta(days=1)).isoformat()}\n"
        "targets:\n"
        "  - example.com\n"
        "  - 127.0.0.0/8\n"
    )

    state_dir = work / "state"
    state_dir.mkdir()

    env = dict(os.environ)
    env["PATH"] = f"{stub_bin}:{env['PATH']}"
    env["XDG_STATE_HOME"] = str(state_dir)
    env["SHINOBI_ENGAGEMENT"] = "e2e"
    env["SHINOBI_ENGAGEMENTS_DIR"] = str(engagements)
    env["SHINOBI_TOOLS_DIR"] = str(REPO / "tools")
    env["SHINOBI_APPROVAL_CLI"] = str(REPO / "bin/shinobi-approval")
    env["PYTHONPATH"] = str(REPO / "mcp-servers/shinobi-recon")

    # Launch the way the shipped entry point does: import the package and call
    # main(), exactly what the shinobi-recon console script runs. Importing by
    # file path would work too now, but it is not what installs, and a test that
    # exercises a different entry point than production proves less.
    params = StdioServerParameters(
        command=PYTHON,
        args=["-c", "from shinobi_recon.server import main; main()"],
        env=env,
    )

    print("== the server starts and loads every manifest ==")
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = {t.name for t in (await session.list_tools()).tools}
            check("all four manifest-backed tools are served", len(tools), 4)
            for name in ("dns_lookup", "http_headers", "nmap_scan", "whatweb_scan"):
                check(f"{name} is exposed", name in tools, True)

            print("== scope authorizes and refuses ==")
            out = await session.call_tool("dns_lookup", {"target": "example.com"})
            check_contains("an in-scope dns_lookup succeeds", str(out.content[0].text), "example.com")
            out = await session.call_tool("dns_lookup", {"target": "not-in-scope.example.org"})
            check_contains(
                "an out-of-scope dns_lookup is refused",
                str(out.content[0].text),
                "not in the authorized scope",
            )

            print("== a passive tool runs its manifest-declared binary ==")
            out = await session.call_tool("whatweb_scan", {"target": "example.com"})
            check_contains("whatweb_scan reaches the whatweb binary", str(out.content[0].text), "whatweb stub")
            argv = (work / "whatweb-argv").read_text()
            check_contains("whatweb got the manifest's arguments", argv, "--no-errors")

            print("== a misspelled argument is refused, not defaulted ==")
            # This exact call used to succeed. `preset` is not a parameter --
            # nmap_scan declares `profile` -- and mcp drops unknown keys
            # silently, so the scan ran on the default profile and reported
            # success. Because quick is *also* the default, no assertion here
            # could tell the two apart, which is how the mistake stayed
            # invisible. It is kept as a regression case: the bug is the test.
            out = await session.call_tool("nmap_scan", {"target": "example.com", "preset": "quick"})
            text = str(out.content[0].text)
            check_contains("an unknown argument is refused", text, "unknown argument")
            check_contains("the refusal names the offending argument", text, "preset")
            check_contains("the refusal lists what is accepted instead", text, "profile")
            check("nothing was executed for a malformed call", (work / "nmap-argv").exists(), False)

            # Not nmap-specific: any tool with a closed parameter set.
            out = await session.call_tool("http_headers", {"target": "example.com", "schem": "http"})
            check_contains(
                "another tool's misspelled argument is refused too",
                str(out.content[0].text),
                "unknown argument",
            )

            print("== an active tool is refused without an approval ==")
            # profile=service, not the default quick, so the argv assertions
            # below can prove the requested profile is the one that ran.
            out = await session.call_tool("nmap_scan", {"target": "example.com", "profile": "service"})
            text = str(out.content[0].text)
            check_contains("nmap_scan without approval is refused", text, "approval")
            check("nmap was never executed", (work / "nmap-argv").exists(), False)

            print("== a human approves that exact call, and it proceeds ==")
            requests = json.loads(
                subprocess.run(
                    [str(REPO / "bin/shinobi-approval"), "list", "--json"],
                    env={**env, "XDG_STATE_HOME": str(state_dir)},
                    capture_output=True, text=True, check=True,
                ).stdout
            )
            check("an approval request was created", len(requests) >= 1, True)
            approval_id = requests[0]["approval_id"]

            subprocess.run(
                [str(REPO / "bin/shinobi-approval"), "approve", approval_id],
                env={**env, "XDG_STATE_HOME": str(state_dir)},
                capture_output=True, text=True, check=True,
            )
            out = await session.call_tool(
                "nmap_scan", {"target": "example.com", "profile": "service", "approval_id": approval_id}
            )
            check_contains("the approved nmap_scan runs", str(out.content[0].text), "nmap stub output")
            check("nmap actually executed", (work / "nmap-argv").exists(), True)

            print("== the requested profile is the one that ran, not the default ==")
            # This is the assertion that could not exist before. Checking that
            # argv mentions "nmap" proves nothing -- the stub echoes its own
            # $0, so that passed whatever profile was selected. These flags are
            # specific to the service profile, and -F is specific to quick, so
            # both directions are pinned: the requested profile reached nmap,
            # and the default's flags were not silently used instead.
            argv = (work / "nmap-argv").read_text()
            check_contains("the manifest's service-profile version flag reached nmap", argv, "-sV")
            check_contains("and its script flag too", argv, "-sC")
            check("the default quick profile's -F was not used", "-F" in argv, False)

            print("== the approval cannot be spent twice ==")
            out = await session.call_tool(
                "nmap_scan", {"target": "example.com", "profile": "service", "approval_id": approval_id}
            )
            check_contains("replaying the approval is refused", str(out.content[0].text), "approval")

            print("== an approval is bound to its exact arguments ==")
            # Same tool, same target, different profile. A different profile is
            # a different probe, so an approval granted for one must not pay
            # for another. This block used to re-list the approvals, throw the
            # result away, and assert nothing.
            await session.call_tool("nmap_scan", {"target": "example.com", "profile": "quick"})
            listed = json.loads(
                subprocess.run(
                    [str(REPO / "bin/shinobi-approval"), "list", "--json"],
                    env={**env, "XDG_STATE_HOME": str(state_dir)},
                    capture_output=True, text=True, check=True,
                ).stdout
            )
            pending = [r for r in listed if r.get("state") == "pending"]
            check("a second approval request was created for the quick profile", len(pending), 1)
            second_id = pending[0]["approval_id"] if pending else ""
            subprocess.run(
                [str(REPO / "bin/shinobi-approval"), "approve", second_id],
                env={**env, "XDG_STATE_HOME": str(state_dir)},
                capture_output=True, text=True, check=True,
            )
            out = await session.call_tool(
                "nmap_scan", {"target": "example.com", "profile": "service", "approval_id": second_id}
            )
            check_contains(
                "an approval for quick cannot be spent on a service scan",
                str(out.content[0].text),
                "different arguments",
            )

    print("== the audit trail records intent and result, allowed and refused ==")
    records = audit_records(engagement)
    verdicts = {r.get("verdict") for r in records}
    phases = {r.get("phase") for r in records}
    check("allowed calls are logged", "allowed" in verdicts, True)
    check("refused calls are logged", "refused" in verdicts, True)
    check("an intent record precedes the result", "intent" in phases and "result" in phases, True)
    check("every record names its tool", all("tool" in r for r in records), True)

    # A refusal with no audit record would break the invariant the whole
    # server is built on, so the malformed-call refusals are checked for by
    # name. The args assertion also pins that the log keeps the rejected key
    # name and not its value: the value is unvalidated model text, and there
    # is no reason to persist it.
    malformed = [r for r in records if "unknown argument" in str(r.get("detail", ""))]
    check("an unknown-argument refusal reached the audit log", len(malformed) >= 2, True)
    if malformed:
        check("it names the argument instead of logging its value", "preset" in malformed[0]["args"], True)
        check("and it kept the target when the client spelled it right", malformed[0]["target"], "example.com")

    print()
    if failures:
        print(f"mcp-e2e: FAIL ({len(failures)} of {passes + len(failures)} checks failed)")
        for name in failures:
            print(f"  - {name}")
        return 1
    print(f"{passes}/{passes} checks passed")
    print("mcp-e2e: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
