#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - <<PY
import sys
sys.path.insert(0, "$ROOT/mcp-servers/shinobi-recon")
from shinobi_recon.process import run

result = run(["printf", "ok"], timeout=10)
assert result.stdout == "ok" and result.returncode == 0 and not result.timed_out
missing = run(["shinobi-command-does-not-exist"], timeout=1)
assert missing.returncode == 127 and "not found" in missing.stderr
print("tool-process-test: PASS")
PY
