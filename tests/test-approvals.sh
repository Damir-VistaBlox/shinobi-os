#!/usr/bin/env bash
# Tests for the approval flow and the policy fields that were declared but
# never enforced.
#
# The control plane's three built-in capabilities are all read-only, so none
# of them requires approval and the approval branch of the dispatcher was
# unreachable. The machinery around it -- request, approve, claim -- was
# never exercised by anything, which is how an approval system ends up
# non-functional while every test still passes. These tests drive the whole
# round trip against capabilities that do require approval.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The parent of the package, matching how production imports it: the agentd
# script sits beside shinobi_control/ and Python puts the script's directory on
# sys.path.
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import asyncio
import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import threading
from pathlib import Path

from shinobi_control import approval, policy
from shinobi_control.daemon import AgentDaemon
from shinobi_control.protocol import Request
from shinobi_control.registry import Capability

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


state = Path(tempfile.mkdtemp(prefix="shinobi-approval-state-"))
os.environ["XDG_STATE_HOME"] = str(state)
os.environ.pop("SHINOBI_ENGAGEMENT", None)
CAP = "test.privileged.reboot"
ARGS = {"host": "10.0.0.5", "mode": "graceful"}


def granted(ttl=300, arguments=None):
    record = approval.create(
        capability=CAP, arguments=arguments if arguments is not None else ARGS,
        profile="operator", reason="test", ttl_seconds=ttl,
    )
    approval.set_state(record["approval_id"], "approved")
    return record["approval_id"]


try:
    print("== approval lifecycle ==")
    record = approval.create(capability=CAP, arguments=ARGS, profile="operator", reason="test")
    check(record["state"] == "pending", "a new request starts pending")
    check("live_mode" in record, "the request records the live/installed context")
    on_disk = json.loads((approval.approval_dir() / f"{record['approval_id']}.json").read_text())
    check(on_disk == record, "the stored record matches what was returned")
    mode = (approval.approval_dir() / f"{record['approval_id']}.json").stat().st_mode & 0o777
    check(mode == 0o600, f"the record is owner-only (got {mode:o})")

    try:
        approval.consume(record["approval_id"], capability=CAP, arguments=ARGS)
        check(False, "a pending approval cannot be consumed")
    except approval.ApprovalError as exc:
        check("pending" in str(exc), f"a pending approval cannot be consumed ({exc})")

    approval.set_state(record["approval_id"], "approved")
    try:
        approval.consume(record["approval_id"], capability=CAP, arguments=ARGS)
        check(True, "an approved approval is consumed")
    except approval.ApprovalError as exc:
        check(False, f"an approved approval is consumed (refused: {exc})")

    print("== single use ==")
    try:
        approval.consume(record["approval_id"], capability=CAP, arguments=ARGS)
        check(False, "an approval cannot be used twice")
    except approval.ApprovalError as exc:
        check("already used" in str(exc), f"an approval cannot be used twice ({exc})")

    fresh = granted()
    approval.consume(fresh, capability=CAP, arguments=ARGS)
    check(True, "a second, independent approval works")

    print("== argument binding ==")
    # The whole point: approving one call must not authorize another.
    for label, other in [
        ("different host", {**ARGS, "host": "10.0.0.6"}),
        ("different mode", {**ARGS, "mode": "force"}),
        ("extra argument", {**ARGS, "extra": True}),
        ("missing argument", {"host": "10.0.0.5"}),
    ]:
        bound = granted(arguments=ARGS)
        try:
            approval.consume(bound, capability=CAP, arguments=other)
            check(False, f"approval is not reusable for a {label} call")
        except approval.ApprovalError:
            check(True, f"approval is not reusable for a {label} call")

    # Key order must not matter; the binding is on content, not serialization.
    reordered = granted(arguments=ARGS)
    try:
        approval.consume(reordered, capability=CAP, arguments={"mode": "graceful", "host": "10.0.0.5"})
        check(True, "argument binding ignores key order")
    except approval.ApprovalError as exc:
        check(False, f"argument binding ignores key order (refused: {exc})")

    print("== capability and profile binding ==")
    other_cap = granted()
    try:
        approval.consume(other_cap, capability="test.other", arguments=ARGS)
        check(False, "an approval is bound to its capability")
    except approval.ApprovalError:
        check(True, "an approval is bound to its capability")

    other_profile = granted()
    try:
        approval.consume(other_profile, capability=CAP, arguments=ARGS, profile="emergency")
        check(False, "an approval is bound to the profile that requested it")
    except approval.ApprovalError:
        check(True, "an approval is bound to the profile that requested it")

    print("== expiry ==")
    expired = granted(ttl=-1)
    try:
        approval.consume(expired, capability=CAP, arguments=ARGS)
        check(False, "an expired approval is refused")
    except approval.ApprovalError as exc:
        check("expired" in str(exc), f"an expired approval is refused ({exc})")

    print("== invalid ids ==")
    for bad in ["", "../../etc/passwd", "a/b", ".hidden", "..", "with space", "x" * 200]:
        try:
            approval.consume(bad, capability=CAP, arguments=ARGS)
            check(False, f"rejects approval id {bad!r}")
        except (approval.ApprovalError, FileNotFoundError):
            check(True, f"rejects approval id {bad!r}")

    print("== concurrent single use ==")
    # Two callers racing for one approval: exactly one must win. The claim is
    # an O_EXCL create, so this cannot double-spend.
    raced = granted()
    outcomes = []
    barrier = threading.Barrier(2)

    def attempt():
        barrier.wait()
        try:
            approval.consume(raced, capability=CAP, arguments=ARGS)
            outcomes.append("won")
        except approval.ApprovalError as exc:
            outcomes.append(f"lost:{exc}")

    threads = [threading.Thread(target=attempt) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    check(outcomes.count("won") == 1, f"exactly one of two racers consumed the approval (got {outcomes})")

    print("== policy fields that were declared but never enforced ==")
    # Keyword arguments throughout: this dataclass has ten fields, and
    # positional construction silently set live_mode=True on every capability
    # in the first version of this test, which made the live_mode checks pass
    # for the wrong reason.
    def capability(**overrides):
        fields = dict(
            id="test.x", summary="test", risk="low", privilege="unprivileged",
            requires_engagement=False, requires_approval=False, live_mode=False,
            audit=True, timeout=10, handler=lambda a: {},
        )
        fields.update(overrides)
        return Capability(**fields)

    unprivileged = capability
    needs_engagement = lambda: capability(requires_engagement=True)
    live_only = lambda: capability(live_mode=True)
    needs_approval = lambda: capability(id=CAP, requires_approval=True)

    ok, reason = policy.allowed(unprivileged(), profile="observer", engagement="acme", live=False)
    check(ok, f"a plain capability is allowed off the live image too ({reason})")
    ok, reason = policy.allowed(live_only(), profile="observer", engagement="acme", live=False)
    check(not ok, f"a live-only capability is refused off the live image ({reason})")

    ok, reason = policy.allowed(needs_engagement(), profile="observer", engagement="", live=True)
    check(not ok and "engagement" in reason, f"requires_engagement is enforced with no engagement ({reason})")
    ok, reason = policy.allowed(needs_engagement(), profile="observer", engagement="acme", live=True)
    check(ok, f"requires_engagement is satisfied by an active engagement ({reason})")

    ok, reason = policy.allowed(live_only(), profile="observer", engagement="acme", live=False)
    check(not ok and "live" in reason, f"live_mode is enforced off the live image ({reason})")
    ok, reason = policy.allowed(live_only(), profile="observer", engagement="acme", live=True)
    check(ok, f"live_mode is satisfied on the live image ({reason})")

    ok, reason = policy.allowed(needs_approval(), profile="operator", engagement="acme", live=True, arguments=ARGS)
    check(not ok and reason == "explicit approval required", f"an approval-requiring capability asks for approval ({reason})")

    good = granted()
    ok, reason = policy.allowed(needs_approval(), profile="operator", engagement="acme", live=True, arguments=ARGS, approval_id=good)
    check(ok, f"a valid approval lets the capability run ({reason})")
    ok, reason = policy.allowed(needs_approval(), profile="operator", engagement="acme", live=True, arguments=ARGS, approval_id=good)
    check(not ok, f"the spent approval does not work twice ({reason})")

    print("== daemon round trip ==")

    async def drive():
        socket_path = state / "test-agent.sock"
        daemon = AgentDaemon(socket_path)
        ran = []
        daemon.capabilities = {
            "test.approve-me": capability(
                id="test.approve-me", summary="needs approval", requires_approval=True,
                handler=lambda a: {"ran": True, "args": a},
            ),
            "test.needs-engagement": capability(
                id="test.needs-engagement", summary="needs engagement",
                requires_engagement=True, handler=lambda a: {"ran": True},
            ),
        }
        await daemon.start()
        try:
            # 1. no approval -> approval-required, with an id to hand a human
            r = await daemon.dispatch(Request("r1", "test.approve-me", {"host": "h1"}))
            check(r["status"] == "approval-required", f"dispatch without approval asks for one (got {r['status']})")
            approval_id = r.get("approval_id")
            check(bool(approval_id), "the approval-required response carries an id")

            # 2. still pending -> denied
            r = await daemon.dispatch(Request("r2", "test.approve-me", {"host": "h1", "approval_id": approval_id}))
            check(r["status"] == "denied", f"a pending approval does not run the capability (got {r['status']})")

            # 3. approve, then run
            approval.set_state(approval_id, "approved")
            r = await daemon.dispatch(Request("r3", "test.approve-me", {"host": "h1", "approval_id": approval_id}))
            check(r["status"] == "completed", f"an approved request runs the capability (got {r['status']}: {r.get('error','')})")
            check(
                r.get("result", {}).get("args") == {"host": "h1"},
                f"approval_id is stripped before the handler sees arguments (got {r.get('result', {}).get('args')})",
            )

            # 4. the same approval cannot be spent twice
            r = await daemon.dispatch(Request("r4", "test.approve-me", {"host": "h1", "approval_id": approval_id}))
            check(r["status"] == "denied", f"a spent approval is refused on a second call (got {r['status']})")

            # 5. an approval for different arguments is refused
            r = await daemon.dispatch(Request("r5", "test.approve-me", {"host": "h1"}))
            second = r.get("approval_id")
            approval.set_state(second, "approved")
            r = await daemon.dispatch(Request("r6", "test.approve-me", {"host": "h2", "approval_id": second}))
            check(r["status"] == "denied", f"an approval is bound to its exact arguments (got {r['status']})")

            # 6. a non-string approval_id is a protocol error, not a crash
            r = await daemon.dispatch(Request("r7", "test.approve-me", {"host": "h1", "approval_id": 12345}))
            check(r["status"] == "denied", f"a non-string approval_id is denied cleanly (got {r['status']})")

            # 7. requires_engagement is enforced through dispatch, in both
            #    directions, using the same state file the CLI writes.
            engagement_file = state / "shinobi/current-engagement"
            engagement_file.parent.mkdir(parents=True, exist_ok=True)
            check(
                not engagement_file.exists(),
                "no engagement is selected to begin with",
            )
            r = await daemon.dispatch(Request("r8", "test.needs-engagement", {}))
            check(
                r["status"] == "denied" and "engagement" in r.get("error", ""),
                f"an engagement-gated capability is denied with none selected (got {r['status']}: {r.get('error','')})",
            )
            engagement_file.write_text("acme\n", encoding="utf-8")
            r = await daemon.dispatch(Request("r9", "test.needs-engagement", {}))
            check(
                r["status"] == "completed",
                f"the same capability runs once an engagement is selected (got {r['status']}: {r.get('error','')})",
            )
        finally:
            await daemon.close()

    asyncio.run(drive())

finally:
    shutil.rmtree(state, ignore_errors=True)

print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print(f"approval-test: FAIL ({len(failures)} failed)")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)
print("approval-test: PASS")
PY
