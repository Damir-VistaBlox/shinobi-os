#!/bin/sh
# Runs inside a guest under test: fetch commands from the host, run them, send back what
# they printed. The other half is tests/vm-agent.py. It exists because the images have no
# serial login and no ssh, and the one way in that always works is the network QEMU gives
# the guest (the host is 10.0.2.2), reached with curl, which every image has.
#
#   sh guest-agent.sh HOST:PORT SESSION &
#
# Polls http://HOST:PORT/SESSION/cmd.N.sh for N = 1, 2, ...; runs each with `sh -c`, as
# whoever started this; uploads its output, ending with a line `rc=<status>`, to
# /SESSION/out.N. It stops asking for commands only when killed.
base="http://${1:?host:port}/${2:?session}"
# One agent per session: a second would run every command again. (The host retries the line
# that starts this when it does not hear back, and the first may only have been slow.)
mkdir "${TMPDIR:-/tmp}/guest-agent.$2.lock" 2>/dev/null || exit 0
out="${TMPDIR:-/tmp}/agent-out"
n=0
while sleep 1; do
  cmd=$(curl -sf "$base/cmd.$((n + 1)).sh") || continue
  n=$((n + 1))
  sh -c "$cmd" >"$out.$n" 2>&1
  echo "rc=$?" >>"$out.$n"
  curl -s -T "$out.$n" "$base/out.$n" >/dev/null 2>&1
done
