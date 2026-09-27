#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'kill "${daemon_pid:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export XDG_RUNTIME_DIR="$tmp/runtime" XDG_STATE_HOME="$tmp/state" SHINOBI_AUDIT_FILE="$tmp/state/shinobi/audit.jsonl"
mkdir -p "$XDG_RUNTIME_DIR"
python3 "$ROOT/libexec/shinobi/shinobi-agentd" & daemon_pid=$!
for _ in {1..50}; do [[ -S "$XDG_RUNTIME_DIR/shinobi/agent.sock" ]] && break; sleep 0.05; done
[[ -S "$XDG_RUNTIME_DIR/shinobi/agent.sock" ]]
status="$(python3 "$ROOT/libexec/shinobi/shinobi-agentctl" agent.status)"
grep -q '"status": "completed"' <<<"$status"
caps="$(python3 "$ROOT/libexec/shinobi/shinobi-agentctl" agent.capabilities)"
grep -q 'system.status' <<<"$caps"
notify="$(python3 -c 'import json,os,socket; p={"protocol":1,"request_id":"test-1","capability":"desktop.notify","arguments":{"title":"test","body":"control-plane"}}; s=socket.socket(socket.AF_UNIX); s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"],"shinobi/agent.sock")); s.sendall((json.dumps(p)+"\n").encode()); print(s.recv(65536).decode(),end="")')"
grep -q '"completed"' <<<"$notify"
[[ -s "$SHINOBI_AUDIT_FILE" ]]
echo 'control-plane-test: PASS'
