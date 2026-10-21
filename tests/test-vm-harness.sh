#!/usr/bin/env bash
# Tests the pieces the end-to-end install test drives a guest with, without a guest.
#
# tests/test-install-e2e.sh boots an image, types into it through QEMU's monitor, and
# runs commands in it through a small agent over QEMU's network. None of that can run
# without an image and KVM, so a typo in any of it would be found twenty-five minutes into
# a run, or never. The parts that do not need a guest are here, and are in run-all.sh:
#
#   - tests/vm-drive.py's translation from text to the key presses of a layout, against the
#     real xkb library (the property the e2e test depends on: the same presses are
#     different characters on different layouts);
#   - its screenshot and key commands, against a stand-in for QEMU's monitor socket;
#   - tests/vm-agent.py and tests/fixtures/guest-agent.sh talking to each other, and the
#     server refusing what it should (it is serving a guest that is the thing under test).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE="$ROOT/tests/vm-drive.py"
AGENT_SERVER="$ROOT/tests/vm-agent.py"
GUEST_AGENT="$ROOT/tests/fixtures/guest-agent.sh"

work="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null; done
  rm -rf -- "$work"
}
trap cleanup EXIT

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

drive() { python3 -I "$DRIVE" "$@"; }

echo "== the keys that type a string, on the layout the operator has =="
if ! drive translate a >/dev/null 2>&1; then
  printf '  FAIL the real xkb library is needed (libxkbcommon0 and xkb-data): %s\n' \
    "$(drive translate a 2>&1 | tail -1)"
  failures=$((failures + 1))
  checks=$((checks + 1))
else
  check "on us a string is its own key names" "$(drive translate --layout us 'ab1')" "a b 1"
  check "shifted characters press shift and the key" "$(drive translate --layout us 'A!')" "shift-a shift-1"
  check "punctuation uses QEMU's names for the keys" "$(drive translate --layout us 'a-b.c/d')" \
    "a minus b dot c slash d"
  check "a newline is Enter, and --enter adds one" "$(drive translate --layout us --enter 'a')" "a ret"
  check "on de the keys for 'zy' are the ones a US keyboard has Y and Z on" \
    "$(drive translate --layout de 'zy')" "y z"
  check "and on us the same two letters are the other way round, which is the whole problem" \
    "$(drive translate --layout us 'zy')" "z y"
  check "on de a minus is on the key a US keyboard has a slash on" \
    "$(drive translate --layout de 'a-b')" "a slash b"
  check "on fr azerty 'a' is the key a US keyboard has Q on" "$(drive translate --layout fr --variant azerty 'a')" "q"
  check "and a digit needs shift there" "$(drive translate --layout fr --variant azerty '1')" "shift-1"
  rc=0
  drive translate --layout de '@' >"$work/out" 2>"$work/err" || rc=$?
  check "a character that needs AltGr is an error, not a guess" \
    "$rc|$(grep -c 'AltGr' "$work/err" || true)" "1|1"
  rc=0
  drive translate --layout us 'é' >"$work/out" 2>"$work/err" || rc=$?
  check "and so is one the layout cannot type" "$rc|$(grep -c 'cannot type' "$work/err" || true)" "1|1"
  rc=0
  drive translate --layout nonesuch 'a' >"$work/out" 2>"$work/err" || rc=$?
  check "and a layout xkb does not know" "$([[ $rc != 0 ]] && echo refused || echo accepted)" "refused"
fi

echo "== the monitor commands, against a stand-in for QEMU's =="
cat >"$work/fake-monitor.py" <<'EOF'
import os, socket, sys
sock_path, log_path = sys.argv[1], sys.argv[2]
server = socket.socket(socket.AF_UNIX)
server.bind(sock_path)
server.listen(4)
# Like QEMU's monitor, one client after another: every vm-drive.py call is a new connection.
while True:
    conn, _ = server.accept()
    conn.sendall(b"QEMU monitor\n(qemu) ")
    buffer = b""
    while True:
        data = conn.recv(4096)
        if not data:
            break
        buffer += data
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            line = line.decode()
            with open(log_path, "a") as log:
                log.write(line + "\n")
            if line.startswith("screendump "):
                with open(line.split(" ", 1)[1], "wb") as ppm:
                    ppm.write(b"P6\n3 2\n255\n" + bytes(range(18)))
            conn.sendall(b"(qemu) ")
            if line == "quit":
                sys.exit(0)
EOF
python3 -I "$work/fake-monitor.py" "$work/mon.sock" "$work/mon.log" &
pids+=("$!")
for _ in $(seq 1 50); do [[ -S $work/mon.sock ]] && break; sleep 0.1; done
drive --monitor "$work/mon.sock" keys --gap 0 a 'b*2' ret
drive --monitor "$work/mon.sock" type --layout de --gap 0 --enter 'zy'
drive --monitor "$work/mon.sock" shot "$work/shot.png"
drive --monitor "$work/mon.sock" quit
check "keys sends one sendkey per key, expanding NAME*COUNT" \
  "$(grep -c '^sendkey' <(head -4 "$work/mon.log") || true)|$(sed -n '1,4p' "$work/mon.log" | tr '\n' ',')" \
  "4|sendkey a,sendkey b,sendkey b,sendkey ret,"
check "type sends the keys of the layout, and Enter" \
  "$(sed -n "5,7p" "$work/mon.log" | tr '\n' ',')" "sendkey y,sendkey z,sendkey ret,"
# A list widget's type-ahead forgets what was typed after about 400 ms, so typing must not be
# slower than that between keys. It used to take five seconds a key, because reading the
# monitor's reply waited for the socket to time out, and "german" arrived as "n".
started=$(date +%s.%N)
drive --monitor "$work/mon.sock" type --gap 0 'abcdefghijklmnopqrstuvwxyz0123'
elapsed=$(python3 -I -c "print(round($(date +%s.%N) - $started, 1))")
check "thirty keys are typed in well under a second each, so type-ahead sees one word" \
  "$(python3 -I -c "print('fast' if $elapsed < 4 else 'slow')")" "fast"
check "shot asks for a screendump" "$(grep -c '^screendump ' "$work/mon.log" || true)" "1"
check "and writes a PNG of the screen's size" \
  "$(python3 -I - "$work/shot.png" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
print(data[:8] == b"\x89PNG\r\n\x1a\n", struct.unpack(">II", data[16:24]))
PY
)" "True (3, 2)"
check "and leaves no screendump behind" "$(ls "$work"/*.ppm 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== the agent: host and guest halves =="
mkdir -p "$work/serve/live"
python3 -I "$AGENT_SERVER" "$work/serve" >"$work/server.out" 2>&1 &
pids+=("$!")
for _ in $(seq 1 50); do grep -q '^PORT ' "$work/server.out" 2>/dev/null && break; sleep 0.1; done
port="$(sed -n 's/^PORT //p' "$work/server.out")"
check "the server reports the port it is on" "$([[ $port =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes"
TMPDIR="$work" sh "$GUEST_AGENT" "127.0.0.1:$port" live >/dev/null 2>&1 &
pids+=("$!")
wait_for() { for _ in $(seq 1 100); do [[ -f $1 ]] && return 0; sleep 0.1; done; return 1; }
printf 'echo hello; exit 3\n' >"$work/serve/live/cmd.1.sh"
wait_for "$work/serve/live/out.1"
check "a command runs in the guest, and what it printed and its status come back" \
  "$(tr '\n' '|' <"$work/serve/live/out.1")" "hello|rc=3|"
printf 'echo "second"\n' >"$work/serve/live/cmd.2.sh"
wait_for "$work/serve/live/out.2"
check "and the next one runs after it, in order" "$(tr '\n' '|' <"$work/serve/live/out.2")" "second|rc=0|"
printf 'echo "two words"\n' >"$work/serve/live/cmd.3.sh"
wait_for "$work/serve/live/out.3"
check "output with spaces survives" "$(head -1 "$work/serve/live/out.3")" "two words"

put() { curl -s -o /dev/null -w '%{http_code}' -T "$2" "http://127.0.0.1:$port$1"; }
printf 'x' >"$work/payload"
check "an upload outside the session's out.N pattern is refused" "$(put /live/evil.sh "$work/payload")" "400"
check "so is one that tries to leave the directory" \
  "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is -T "$work/payload" "http://127.0.0.1:$port/live/../out.9")" "400"
check "so is one into a session that does not exist" "$(put /nosuch/out.1 "$work/payload")" "404"
head -c $((4 * 1024 * 1024 + 1)) /dev/zero >"$work/big"
check "and an oversized one" "$(put /live/out.7 "$work/big")" "400"
check "the files outside the served directory are not served" \
  "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$port/../../../../etc/passwd")" "404"
check "and a missing command is a 404, which is how the agent knows to wait" \
  "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/live/cmd.99.sh")" "404"

echo
if ((failures > 0)); then
  echo "vm-harness-test: FAIL ($failures of $checks checks)"
  exit 1
fi
printf '%d/%d checks passed\nvm-harness-test: PASS\n' "$checks" "$checks"
