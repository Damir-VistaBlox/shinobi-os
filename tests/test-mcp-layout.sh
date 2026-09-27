#!/usr/bin/env bash
# Tests for the MCP server's module layout.
#
# The package contained a module named http.py. That is a legal name inside a
# package, but only while the package directory is not on sys.path -- and running
# `python shinobi_recon/server.py`, which a maintainer will try at some point,
# puts exactly that directory there. The stdlib's own http package then resolves
# to this file, and `import http.client` inside urllib.request fails with "'http'
# is not a package". The traceback points into urllib rather than at the real
# cause.
#
# The supported entry point (the shinobi-recon console script) is unaffected,
# which is why it survived and why the unit suites looked green. The module is
# now httpclient.py. These checks pin both halves so the name cannot quietly
# come back: no module shadows a stdlib name, and the stdlib still resolves
# correctly with the package directory on the path.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/mcp-servers/shinobi-recon/shinobi_recon"

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

echo "== no module shadows a stdlib name =="
# A module named after a stdlib top-level package works right up until something
# puts this directory on sys.path, at which point it breaks unrelated imports in
# a way that points nowhere near the cause.
stdlib_names="$(python3 -c 'import sys; print("\n".join(sorted(sys.stdlib_module_names)))')"
for module in "$PKG"/*.py; do
  name="$(basename "$module" .py)"
  [[ "$name" == "__init__" ]] && continue
  if grep -qx "$name" <<<"$stdlib_names"; then
    check "$name.py does not shadow the stdlib $name module" "shadowed" "free"
  else
    check "$name.py does not shadow a stdlib module" "free" "free"
  fi
done

echo "== the stdlib survives the package directory being on sys.path =="
# This is the mechanism, tested directly rather than through a server start, so
# it holds without the mcp package installed.
result="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
try:
    import http.client, http.server
except Exception as exc:
    print("broken: %s: %s" % (type(exc).__name__, exc))
else:
    print("intact")
' "$PKG" 2>&1)"
check "stdlib http still works with the package dir on sys.path" "$result" "intact"

resolved="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import http
print("stdlib" if "lib/python" in http.__file__ else http.__file__)
' "$PKG" 2>/dev/null || echo broken)"
check "and http resolves to the stdlib, not to this package" "$resolved" "stdlib"

echo "== importing the package does not disturb the stdlib =="
check "urllib.request is importable after the package" \
  "$(PYTHONPATH="$ROOT/mcp-servers/shinobi-recon" python3 -c 'import shinobi_recon.scope, urllib.request; print("yes")' 2>/dev/null || echo no)" "yes"
check "shinobi_recon.httpclient imports cleanly" \
  "$(PYTHONPATH="$ROOT/mcp-servers/shinobi-recon" python3 -c 'import shinobi_recon.httpclient; print("yes")' 2>/dev/null || echo no)" "yes"
check "shinobi_recon.scope imports cleanly" \
  "$(PYTHONPATH="$ROOT/mcp-servers/shinobi-recon" python3 -c 'import shinobi_recon.scope; print("yes")' 2>/dev/null || echo no)" "yes"

echo "== nothing references the old module name =="
check "no source file imports shinobi_recon.http" \
  "$(grep -rn 'from \.http import\|from shinobi_recon\.http import' "$PKG" --include='*.py' 2>/dev/null | grep -v __pycache__ | wc -l | tr -d ' ')" "0"
check "the docs point at the current name" \
  "$(grep -q 'shinobi_recon/http\.py' "$ROOT/mcp-servers/shinobi-recon/README.md" && echo stale || echo current)" "current"
check "the old file is gone" \
  "$([[ -f "$PKG/http.py" ]] && echo present || echo absent)" "absent"

echo
if (( failures > 0 )); then
  printf 'mcp-layout-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nmcp-layout-test: PASS\n' "$checks" "$checks"
