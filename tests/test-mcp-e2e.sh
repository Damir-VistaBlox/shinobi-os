#!/usr/bin/env bash
# End-to-end check of the real shinobi-recon MCP server over stdio.
#
# The rest of the suite tests the scope gate, the approval CLI and the registry
# as units. None of them proves the assembled server works: that the four tools
# are actually served, that an in-scope call reaches the manifest's binary, that
# an active tool is refused until a human approves that exact call, and that the
# audit trail records both outcomes. That needs a real MCP client talking to a
# real subprocess, which is what tests/mcp-e2e.py does.
#
# Skipped when the mcp package is unavailable, the same way test-package.sh skips
# without dpkg-deb: a missing optional dependency is not a failing server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! python3 -c 'import mcp' >/dev/null 2>&1; then
  echo "mcp-e2e-test: SKIPPED (mcp package unavailable)"
  exit 0
fi

PYTHONPATH="$ROOT/mcp-servers/shinobi-recon" python3 "$ROOT/tests/mcp-e2e.py"
