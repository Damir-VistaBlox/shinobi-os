#!/usr/bin/env bash
# Tests for the config migration stamp.
#
# shinobi-migrate read its state file with `cat` and fed the result straight to
# `[ ... -lt 1 ]`. Any non-integer in that file -- a truncated write, a disk-full
# partial write, a user editing it, a filesystem that returned garbage -- made the
# test error out. The error was the branch's *condition*, so `set -e` did not
# catch it: the migration was skipped, the script still exited 0, and it then
# stamped the current version anyway. The user got a silently un-migrated system
# that would never retry, because the next run read a valid "1".
#
# A corrupt stamp is unknown, and unknown has to mean "run the migrations".
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$ROOT/packaging/shinobi-core/usr/lib/shinobi/shinobi-migrate"

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

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home"
export XDG_STATE_HOME="$work/home/.local/state"
export XDG_CONFIG_HOME="$work/home/.config"
state_file="$XDG_STATE_HOME/shinobi/config-version"

run() { sh "$MIGRATE" >"$work/out" 2>"$work/err"; echo $?; }

stamp() { printf '%s\n' "$1" >"$state_file"; }

echo "== a first run migrates and records the version =="
rm -rf "$HOME"
check "exit status is 0" "$(run)" "0"
check "the config directory was created" "$([[ -d "$XDG_CONFIG_HOME/shinobi" ]] && echo yes || echo no)" "yes"
check "the version was stamped" "$(cat "$state_file" 2>/dev/null)" "1"

echo "== a migrated system is not migrated again =="
rm -rf "$XDG_CONFIG_HOME/shinobi"
check "exit status is 0" "$(run)" "0"
check "the migration was not re-run" "$([[ -d "$XDG_CONFIG_HOME/shinobi" ]] && echo ran || echo skipped)" "skipped"

echo "== a corrupt stamp is treated as unknown, not as up to date =="
# Each of these is what a partial or garbage write looks like. None may be read
# as "already migrated".
for bad in 'abc' '' ' ' '1.5' 'corrupt' '1 2' 'v1' '-' '+1'; do
  rm -rf "$XDG_CONFIG_HOME/shinobi"
  stamp "$bad"
  rc="$(run)"
  check "state $(printf '%q' "$bad") migrates anyway" "$([[ -d "$XDG_CONFIG_HOME/shinobi" ]] && echo ran || echo skipped)" "ran"
  check "state $(printf '%q' "$bad") still exits 0" "$rc" "0"
  check "state $(printf '%q' "$bad") is repaired to 1" "$(cat "$state_file" 2>/dev/null)" "1"
done

echo "== a corrupt stamp says so instead of failing silently =="
rm -rf "$XDG_CONFIG_HOME/shinobi"
stamp 'abc'
run >/dev/null
check "the unreadable stamp is reported on stderr" \
  "$(grep -qi 'unreadable' "$work/err" && echo yes || echo no)" "yes"
check "a clean run says nothing on stderr" \
  "$(rm -rf "$XDG_CONFIG_HOME/shinobi"; stamp 1; run >/dev/null; [[ -s "$work/err" ]] && echo noisy || echo quiet)" "quiet"

echo "== a lower version migrates, a higher one does not =="
rm -rf "$XDG_CONFIG_HOME/shinobi"; stamp 0
run >/dev/null
check "version 0 migrates" "$([[ -d "$XDG_CONFIG_HOME/shinobi" ]] && echo ran || echo skipped)" "ran"
rm -rf "$XDG_CONFIG_HOME/shinobi"; stamp 99
run >/dev/null
check "a version from the future is left alone" "$([[ -d "$XDG_CONFIG_HOME/shinobi" ]] && echo ran || echo skipped)" "skipped"
check "and the future version is not downgraded" "$(cat "$state_file")" "99"

echo "== the stamp is not world-writable =="
# The state directory decides whether migrations run. If another local user can
# write the stamp, they can decide that a system is migrated when it is not.
check "the state directory is private" "$(stat -c '%a' "$XDG_STATE_HOME/shinobi" | tr -d ' ')" "700"
check "the stamp is not world-writable" \
  "$([[ "$(stat -c '%a' "$state_file" | tr -d ' ')" != *"[2367]"* ]] && echo private || echo open)" "private"

echo "== a missing state directory is created =="
rm -rf "$XDG_STATE_HOME"
check "exit status is 0" "$(run)" "0"
check "the state directory exists afterwards" "$([[ -d "$XDG_STATE_HOME/shinobi" ]] && echo yes || echo no)" "yes"

echo
if (( failures > 0 )); then
  printf 'migrate-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nmigrate-test: PASS\n' "$checks" "$checks"
