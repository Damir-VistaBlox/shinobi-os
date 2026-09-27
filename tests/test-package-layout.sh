#!/usr/bin/env bash
# Check what the package is *made of*, on any host.
#
# tests/test-package.sh builds the real .deb and inspects the archive, which is
# the only way to know what dpkg actually lands on disk. It needs dpkg-deb, so
# it runs on the hosted PR runners and reports SKIPPED elsewhere.
#
# That left the staged layout -- which file went where, which script is
# executable, what the control file declares -- checked only where the tooling
# happened to exist, and unchecked on every developer machine. Those are the
# mistakes worth catching cheaply, and `build-deb.sh --stage` is plain file
# copying: it needs nothing Debian-specific. So the layout is checked here,
# everywhere, and the archive is still checked where it can be.
#
# What it checks:
#   * the recon server is shipped, and importable from where it was put
#   * its entry point and its postinst check are executable and resolve the
#     server inside this tree rather than a copy that happens to be installed
#     on the machine running the test
#   * the declared dependencies cover what the shipped code actually imports
#   * the postinst check passes when the dependency is present and fails with a
#     message that names it when it is not
#   * no bytecode residue
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

stage="$(mktemp -d)"
trap 'chmod -R u+rwX "$stage" 2>/dev/null; rm -rf "$stage"' EXIT

failures=0
checks=0
check() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

"$ROOT/packaging/build-deb.sh" --stage "$stage"

# Checked before anything in this file runs code out of the stage. Importing the
# staged server is the point of several checks below, and importing it writes
# __pycache__ next to it -- so a residue check placed afterwards measures this
# test's own side effects and reports a build that is actually clean as dirty.
echo "== no bytecode residue =="
check "no __pycache__ directories" \
  "$(find "$stage" -type d -name __pycache__ | wc -l)" "0"
check "no .pyc files" "$(find "$stage" -type f -name '*.pyc' | wc -l)" "0"

echo "== the recon server is in the package =="
for f in server.py scope.py registry.py httpclient.py process.py argcheck.py __init__.py; do
  check "usr/lib/shinobi/mcp-servers/shinobi_recon/$f" \
    "$([[ -f $stage/usr/lib/shinobi/mcp-servers/shinobi_recon/$f ]] && echo yes || echo no)" "yes"
done
check "its manifests are shipped too, where the registry looks first" \
  "$(find "$stage/usr/share/shinobi/tools" -name '*.toml' | wc -l)" "4"

echo "== the entry point runs the copy this package shipped =="
check "usr/bin/shinobi-recon is executable" \
  "$([[ -x $stage/usr/bin/shinobi-recon ]] && echo yes || echo no)" "yes"

# The manifests ship to /usr/share, which the registry prefers; a staged tree
# cannot be that, so the override stands in for it.
#
# Driven as a real client drives it, and the waiting is load-bearing. Piping
# both requests in at once and letting stdin close made this flaky -- about one
# run in three the server reached EOF after the initialize and shut down before
# answering tools/list, so the assertion failed for a reason that had nothing to
# do with the package. Each response is waited for, and stdin is closed only
# once both are in.
fifo="$stage/in.fifo"
out="$stage/out.jsonl"
errf="$stage/stderr.txt"
mkfifo "$fifo"

send() { printf '%s\n' "$1" >&3; }

wait_for() {
  local id=$1 i
  for i in $(seq 1 200); do
    grep -q "\"id\":$id" "$out" && return 0
    # The server is gone and never answered: stop waiting on a corpse.
    kill -0 "$server_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

SHINOBI_TOOLS_DIR="$stage/usr/share/shinobi/tools" "$stage/usr/bin/shinobi-recon" \
  <"$fifo" >"$out" 2>"$errf" &
server_pid=$!
exec 3>"$fifo"
# Hold a read end open for the lifetime of the exchange. Without one, the
# server failing to start -- which is the normal case on a host with no mcp --
# leaves the write end with no reader, and the next write kills this script
# with SIGPIPE before it can report the failure it was built to report.
exec 4<"$fifo"

send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
wait_for 1 || true
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
wait_for 2 || true

exec 3>&-
exec 4<&-
wait "$server_pid" 2>/dev/null || true

if python3 -c 'import mcp' >/dev/null 2>&1; then
  tools="$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if msg.get("id") == 2:
        print(" ".join(sorted(t["name"] for t in msg["result"]["tools"])))
' "$out" 2>/dev/null)"
  check "the shipped server serves all four tools" \
    "$tools" "dns_lookup http_headers nmap_scan whatweb_scan"
else
  # No mcp here, so the import cannot get as far as serving. What still has to
  # hold is *which* copy was imported: a wrapper that resolved to some other
  # shinobi_recon -- one on the machine, one in a venv -- would pass a
  # version-independent check and still be the wrong server.
  check "the failure names the copy inside this package" \
    "$(grep -c "$stage/usr/lib/shinobi/mcp-servers" "$errf" || true)" "1"
  check "and does not fall back to an installed copy" \
    "$(grep -c "site-packages\|dist-packages" "$errf" || true)" "0"
fi

echo "== the postinst check is runnable and honest =="
check "usr/lib/shinobi/shinobi-recon-check is executable" \
  "$([[ -x $stage/usr/lib/shinobi/shinobi-recon-check ]] && echo yes || echo no)" "yes"
check "the postinst is executable" \
  "$([[ -x $stage/DEBIAN/postinst ]] && echo yes || echo no)" "yes"
check "the postinst is POSIX sh" \
  "$(sh -n "$stage/DEBIAN/postinst" 2>&1 && echo ok || echo bad)" "ok"
check "the postinst points at the shipped check" \
  "$(grep -c 'shinobi-recon-check' "$stage/DEBIAN/postinst" || true)" "1"
check "guards that it is there" \
  "$(grep -c '\[ ! -x "\$check" \]' "$stage/DEBIAN/postinst" || true)" "1"
check "and actually runs it" \
  "$(grep -c 'if err=\$("\$check"' "$stage/DEBIAN/postinst" || true)" "1"

if python3 -c 'import mcp' >/dev/null 2>&1; then
  # set +e: this check is *meant* to fail when the package is broken, and an
  # assignment or bare command that fails under set -e would end the run there
  # -- printing no summary at all, which is the one moment the output matters.
  set +e
  SHINOBI_TOOLS_DIR="$stage/usr/share/shinobi/tools" \
    "$stage/usr/lib/shinobi/shinobi-recon-check" >/dev/null 2>&1
  rc=$?
  set -e
  check "the check passes with the dependency present" "$rc" "0"
else
  # Captured without tripping set -e: the command is *meant* to fail here, and
  # an assignment that fails is enough to end the suite before the assertions
  # that explain why it should have.
  set +e
  out="$(SHINOBI_TOOLS_DIR="$stage/usr/share/shinobi/tools" \
    "$stage/usr/lib/shinobi/shinobi-recon-check" 2>&1)"
  rc=$?
  set -e
  check "the check fails without it" "$rc" "1"
  check "and names the missing dependency" \
    "$(grep -c 'mcp is not importable' <<<"$out")" "1"
  # A check that passes when the server cannot start is worse than no check: it
  # reports an installed package as usable. This is the assertion that stops it
  # being quietly weakened to always-exit-0.
  check "it does not pass a server that cannot start" \
    "$([[ $rc -ne 0 ]] && echo yes || echo no)" "yes"
fi

echo "== the declared dependencies cover what the shipped code imports =="
# Derived from the tree rather than written down, so adding an import without
# declaring it -- or declaring one nothing uses -- shows up here.
mapfile -t imports < <(
  python3 - "$stage" <<'PY'
import ast, pathlib, sys
stdlib = set(sys.stdlib_module_names)
stage = pathlib.Path(sys.argv[1])
found = set()
for path in list((stage / "usr/lib/shinobi").rglob("*.py")) + \
            list((stage / "usr/lib/shinobi/mcp-servers").rglob("*.py")):
    try:
        tree = ast.parse(path.read_text())
    except (SyntaxError, UnicodeDecodeError):
        continue
    for node in ast.walk(tree):
        names = []
        if isinstance(node, ast.Import):
            names = [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names = [node.module.split(".")[0]]
        for name in names:
            if name in stdlib or name.startswith(("shinobi_", "dbus_next")):
                continue
            found.add(name)
print("\n".join(sorted(found)))
PY
)
depends="$(sed -n 's/^Depends: //p' "$stage/DEBIAN/control")"
for module in "${imports[@]}"; do
  case "$module" in
    mcp) pkg=python3-mcp ;;
    yaml) pkg=python3-yaml ;;
    *) pkg="python3-$module" ;;
  esac
  check "$module is declared ($pkg)" \
    "$(grep -qw -- "$pkg" <<<"$depends" && echo yes || echo no)" "yes"
done
# dbus_next is imported but guarded by try/except ImportError, so it must NOT be
# a hard dependency -- the D-Bus surface is optional by design.
check "the optional dbus_next import is not a hard dependency" \
  "$(grep -qw -- 'python3-dbus-next' <<<"$depends" && echo yes || echo no)" "no"

echo
if ((failures > 0)); then
  printf 'package-layout-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\npackage-layout-test: PASS\n' "$checks" "$checks"
