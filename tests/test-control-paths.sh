#!/usr/bin/env bash
# Tests for the control-plane modules that decide *where* data lives.
#
# These are the path-resolution boundaries: given an engagement name and an
# environment, which directory do we read and write? Getting that wrong is
# worse than a crash, because the code keeps working and simply operates on
# the wrong files.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT/libexec/shinobi/shinobi_control${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

import evidencectl

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


root = Path(tempfile.mkdtemp(prefix="shinobi-evidence-"))
attacker = Path(tempfile.mkdtemp(prefix="shinobi-evidence-attacker-"))
# Isolate the state-file fallback. engagement_dir() falls back to
# $XDG_STATE_HOME/shinobi/current-engagement when SHINOBI_ENGAGEMENT is unset,
# so without this the test would read whatever engagement the developer
# actually has active -- which is exactly how the empty-name cases below first
# "passed" against a leftover "demo" engagement.
state = Path(tempfile.mkdtemp(prefix="shinobi-evidence-state-"))
saved = {
    key: os.environ.get(key)
    for key in (
        "SHINOBI_ENGAGEMENT",
        "SHINOBI_ENGAGEMENT_DIR",
        "SHINOBI_ENGAGEMENTS_DIR",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
    )
}


def restore():
    for key, value in saved.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


try:
    # A legitimate engagement, plus a directory the caller might try to
    # redirect us to.
    (root / "acme").mkdir()
    (root / "acme" / "scope.yaml").write_text("window: {start: x, end: y}\ntargets: []\n")
    (attacker / "scope.yaml").write_text("window: {start: x, end: y}\ntargets: ['0.0.0.0/0']\n")

    os.environ["SHINOBI_ENGAGEMENTS_DIR"] = str(root)
    os.environ["SHINOBI_ENGAGEMENT"] = "acme"
    os.environ["SHINOBI_ENGAGEMENT_DIR"] = str(attacker)
    os.environ["XDG_STATE_HOME"] = str(state)

    print("== engagement resolution ==")
    check(
        evidencectl.engagement_dir() == (root / "acme").resolve(),
        f"engagement resolves inside the root (got {evidencectl.engagement_dir()})",
    )
    check(
        evidencectl.engagement_dir() != attacker.resolve(),
        "caller-supplied SHINOBI_ENGAGEMENT_DIR is ignored",
    )

    print("== name validation ==")
    # ".." contains no separator, so the old check ("/" in name) let it
    # through and `root / ".."` walked out of the engagements root.
    for bad in ["..", ".", "../evil", "a/b", "a\\b", "/etc", "", "  ", "-dash", "x" * 65, "with space"]:
        os.environ["SHINOBI_ENGAGEMENT"] = bad
        try:
            result = evidencectl.engagement_dir()
        except ValueError:
            check(True, f"refuses engagement name {bad!r}")
        else:
            check(False, f"refuses engagement name {bad!r} (got {result})")

    print("== symlinked engagement directory ==")
    os.environ["SHINOBI_ENGAGEMENT"] = "linked"
    (root / "linked").symlink_to(attacker)
    try:
        evidencectl.engagement_dir()
    except ValueError as exc:
        check("symlink" in str(exc), f"refuses symlinked engagement dir ({exc})")
    else:
        check(False, "refuses symlinked engagement dir (accepted)")

    print("== evidence filename validation ==")
    for bad in ["..", ".", "", "/etc/passwd", "a/b", "a\\b", ".hidden", "sub/file"]:
        try:
            evidencectl.evidence_name(bad)
        except ValueError:
            check(True, f"refuses evidence name {bad!r}")
        else:
            check(False, f"refuses evidence name {bad!r} (accepted)")
    for good in ["screenshot.png", "capture-1.pcap", "notes.txt", "a.b.c.tar.gz"]:
        try:
            check(evidencectl.evidence_name(good) == good, f"accepts evidence name {good!r}")
        except ValueError as exc:
            check(False, f"accepts evidence name {good!r} (refused: {exc})")

    print("== evidence round trip ==")
    os.environ["SHINOBI_ENGAGEMENT"] = "acme"
    store = evidencectl.evidence_dir()
    check(store == (root / "acme" / "evidence").resolve(), "evidence dir is inside the engagement")
    check(stat.S_IMODE(store.stat().st_mode) == 0o700, f"evidence dir is 0700 (got {stat.S_IMODE(store.stat().st_mode):o})")

    payload = Path(tempfile.mkdtemp(prefix="shinobi-payload-")) / "finding.txt"
    payload.write_text("client-confidential finding\n")
    record = evidencectl.add(payload, "initial access")
    check(record["sha256"] == evidencectl.digest(store / "finding.txt"), "record hash matches the stored file")
    meta = store / "finding.txt.evidence.json"
    check(stat.S_IMODE(meta.stat().st_mode) == 0o600, f"metadata is 0600 (got {stat.S_IMODE(meta.stat().st_mode):o})")

    # Tamper with the stored evidence and confirm the hash check notices.
    (store / "finding.txt").write_text("tampered\n")
    path, rec = evidencectl.find_record("finding.txt")
    check(evidencectl.digest(path) != rec["sha256"], "hash check detects tampered evidence")
    check(
        evidencectl.digest(path) != evidencectl.digest(payload),
        "tampered stored copy no longer matches the original source",
    )

    try:
        evidencectl.find_record("..")
    except ValueError:
        check(True, "find_record rejects '..' by name")
    except Exception as exc:
        check(False, f"find_record rejects '..' by name (raised {type(exc).__name__}: {exc})")
    else:
        check(False, "find_record rejects '..' by name (accepted)")

    print("== export stays engagement-named ==")
    workdir = Path(tempfile.mkdtemp(prefix="shinobi-cwd-"))
    os.chdir(workdir)
    # export() is inlined in main(); this is the default target it computes.
    default_target = workdir / f"{evidencectl.engagement_dir().name}-evidence.tar.gz"
    check(
        default_target.name == "acme-evidence.tar.gz" and default_target.parent == workdir,
        f"default export target is engagement-named (got {default_target.name})",
    )

finally:
    restore()
    for path in (root, attacker, state):
        shutil.rmtree(path, ignore_errors=True)

print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print(f"control-path-test: FAIL ({len(failures)} failed)")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)
print("control-path-test: PASS")
PY
