#!/usr/bin/env bash
# End-to-end smoke test for the control-plane daemon over its real socket.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'kill "${daemon_pid:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export XDG_RUNTIME_DIR="$tmp/runtime" XDG_STATE_HOME="$tmp/state" SHINOBI_AUDIT_FILE="$tmp/state/shinobi/audit.jsonl"
mkdir -p "$XDG_RUNTIME_DIR"

call() {
  python3 -c '
import json, os, socket, sys
payload = {"protocol": 1, "request_id": sys.argv[1], "capability": sys.argv[2], "arguments": json.loads(sys.argv[3])}
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], "shinobi/agent.sock"))
s.sendall((json.dumps(payload) + "\n").encode())
print(s.recv(65536).decode(), end="")
' "$@"
}

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

python3 "$ROOT/libexec/shinobi/shinobi-agentd" & daemon_pid=$!
for _ in {1..50}; do [[ -S "$XDG_RUNTIME_DIR/shinobi/agent.sock" ]] && break; sleep 0.05; done
[[ -S "$XDG_RUNTIME_DIR/shinobi/agent.sock" ]]

status="$(python3 "$ROOT/libexec/shinobi/shinobi-agentctl" agent.status)"
check "agent.status completes" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$status")" "completed"

caps="$(python3 "$ROOT/libexec/shinobi/shinobi-agentctl" agent.capabilities)"
check "system.status is advertised" \
  "$(python3 -c 'import json,sys;print(any(c["id"]=="system.status" for c in json.loads(sys.argv[1])["result"]))' "$caps")" "True"

# The built-in capabilities were all declared live_mode=True, which nothing read.
# Enforcing the field made an installed system unable to notify or read status,
# so the declarations were wrong. This guards against the copy-paste returning.
live_only="$(python3 -c 'import json,sys;print(",".join(sorted(c["id"] for c in json.loads(sys.argv[1])["result"] if c["live_mode"])))' "$caps")"
check "no built-in capability is wrongly restricted to the live image" "$live_only" ""

notify="$(call test-1 desktop.notify '{"title":"test","body":"control-plane"}')"
check "desktop.notify completes off the live image" \
  "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$notify")" "completed"

sys_status="$(call test-2 system.status '{}')"
check "system.status completes off the live image" \
  "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$sys_status")" "completed"
check "system.status reports the live-image context it is running in" \
  "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["result"]["live"])' "$sys_status")" "False"

check "an unknown capability is denied" \
  "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$(call test-3 no.such.capability '{}')")" "denied"

check "a capability with no engagement is not gated by one" \
  "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$(call test-4 context.snapshot '{}')")" "completed"

# Denied rather than ignored: a capability that needs no approval should not
# silently swallow an approval_id, or the caller is left believing a gate was
# applied that never was.
check "a non-string approval_id is denied cleanly, not a crash" \
  "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$(call test-5 system.status '{"approval_id":12345}')")" "denied"

[[ -s "$SHINOBI_AUDIT_FILE" ]]
# Every dispatched call, including the denied ones, leaves an audit record
# keyed by its request id.
check "every dispatched call is audited, denials included" \
  "$(python3 -c '
import json, sys
seen = {json.loads(l).get("request_id") for l in open(sys.argv[1]) if json.loads(l).get("request_id")}
print(",".join(sorted(seen)))
' "$SHINOBI_AUDIT_FILE")" \
  "test-1,test-2,test-3,test-4,test-5"

echo
if (( failures > 0 )); then
  printf 'control-plane-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ncontrol-plane-test: PASS\n' "$checks" "$checks"
