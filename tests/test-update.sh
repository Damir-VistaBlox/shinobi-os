#!/usr/bin/env bash
# Tests `shinobi update check`, the one place a metadata refresh can run twice.
#
# `check` ran `command -v pkexec && pkexec apt-get update || sudo apt-get update`. In
# that shape the `||` is reached whenever pkexec's command fails -- when apt itself
# fails, and when the operator dismisses the authentication prompt -- so a refused or
# failed update was run again, as a different user, straight after. These run it with
# a pkexec, a sudo and an apt-get that only record what they were asked, on a PATH
# that has no real one of any of them, so nothing here can change the machine it runs
# on.
#
# It also checks the helper `shinobi update` shares with every other leaf command for
# "is this the live preview": it listed one medium path twice.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$ROOT/bin/shinobi-update"
COMMON="$ROOT/bin/_shinobi-common.sh"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

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

tools="$work/tools"
fake="$work/fake"
log="$work/log"
mkdir -p "$tools" "$fake" "$log"
for tool in bash sh dirname readlink mkdir date cat sed flock rm; do
  ln -sf "$(command -v "$tool")" "$tools/$tool"
done
for name in pkexec sudo apt-get; do
  cat >"$fake/$name" <<EOF
#!/bin/sh
echo "$name \$*" >>"\$FAKE_LOG/calls"
exit "\${FAKE_${name//-/_}_RC:-0}"
EOF
  chmod +x "$fake/$name"
done

rc=0
# run <VAR=value ...> -- <args>: shinobi-update, in a fresh account, on a PATH of fakes.
run() {
  local -a vars=()
  while [[ $# -gt 0 && $1 != -- ]]; do vars+=("$1"); shift; done
  shift
  rm -rf "$log/calls" "$work/home"
  mkdir -p "$work/home" "$work/run"
  rc=0
  env -i PATH="$fake:$tools" HOME="$work/home" XDG_RUNTIME_DIR="$work/run" FAKE_LOG="$log" \
    XDG_STATE_HOME="$work/home/state" "${vars[@]}" \
    bash "$UPDATE" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
calls() { [[ -f $log/calls ]] && tr '\n' '|' <"$log/calls" || true; }

echo "== a metadata refresh through pkexec runs once =="
run -- check
check "pkexec present and succeeding: one refresh, through pkexec, and no sudo" "$rc|$(calls)" "0|pkexec apt-get update|"
run FAKE_pkexec_RC=0 -- check
check "(the same, set explicitly)" "$rc|$(calls)" "0|pkexec apt-get update|"
run FAKE_pkexec_RC=1 -- check
check "pkexec failing, as when apt fails or the prompt is dismissed: the refresh is NOT run again as someone else" \
  "$rc|$(calls)" "1|pkexec apt-get update|"
run FAKE_pkexec_RC=126 -- check
check "and the status it fails with is pkexec's own (126 is 'dismissed')" "$rc" "126"

echo "== without pkexec it is sudo, once =="
mv "$fake/pkexec" "$work/pkexec.away"
run -- check
check "no pkexec: one refresh, through sudo" "$rc|$(calls)" "0|sudo apt-get update|"
run FAKE_sudo_RC=100 -- check
check "sudo failing: not repeated, and its status is the result" "$rc|$(calls)" "100|sudo apt-get update|"
mv "$work/pkexec.away" "$fake/pkexec"

echo "== a dry run changes nothing and asks nobody =="
run -- check --dry-run
check "check --dry-run simulates the upgrade and uses neither pkexec nor sudo" \
  "$rc|$(calls)" "0|apt-get -s dist-upgrade|"
run SHINOBI_DRY_RUN=1 -- check
check "so does SHINOBI_DRY_RUN=1" "$rc|$(calls)" "0|apt-get -s dist-upgrade|"

echo "== the live preview refuses, before anything is run =="
run SHINOBI_LIVE_MODE=1 -- check
check "on the live preview it fails with 78 and runs nothing" "$rc|$(calls)" "78|"

echo "== what counts as the live preview =="
live_markers="$(sed -n '/^shinobi_is_live() {/,/^}/p' "$COMMON" | grep -oE '/[a-z/]+(medium)' | sort | uniq -c | awk '{print $1}' | sort -u | tr '\n' ' ')"
check "every medium path the live-preview check names is named once" "$live_markers" "1 "
check "and the live-boot mount point is one of them" \
  "$(sed -n '/^shinobi_is_live() {/,/^}/p' "$COMMON" | grep -c '/run/live/medium')" "1"
# Without a real medium to point at, the function is checked against the machine it
# runs on, which is not a live system: no marker file, no override -> not live.
live_here="$(env -i PATH="$tools" bash -c ". '$COMMON'; shinobi_is_live && echo live || echo installed")"
if [[ -e /run/live/medium/live/filesystem.squashfs || -e /lib/live/mount/medium/live/filesystem.squashfs ]]; then
  check "on a live system it says live" "$live_here" "live"
else
  check "on a machine that is not live it says installed" "$live_here" "installed"
fi
check "and SHINOBI_LIVE_MODE=1 overrides that" \
  "$(env -i PATH="$tools" SHINOBI_LIVE_MODE=1 bash -c ". '$COMMON'; shinobi_is_live && echo live || echo installed")" "live"

echo
if ((failures > 0)); then
  echo "update-test: FAIL ($failures of $checks checks)"
  exit 1
fi
printf '%d/%d checks passed\nupdate-test: PASS\n' "$checks" "$checks"
