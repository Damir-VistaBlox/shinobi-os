#!/usr/bin/env bash
# Tests shinobi-installer-autostart: the one script between a boot-menu entry and
# the installation wizard.
#
# It has three jobs, each of which has a way to go quietly wrong. It must start the
# wizard only when the kernel command line says this boot was asked to install (an
# installed system runs the same session config, and a wizard offering to install
# onto the machine it is running from is a lie). It must wait for the desktop to be
# usable, and "usable" has to be something this desktop can say: it used to ask KWin
# over D-Bus, which Hyprland does not have, so every boot waited thirty seconds and
# then claimed the desktop had not reported ready. And when it gives up waiting it
# must start the wizard anyway rather than leave the operator with nothing.
#
# It is run with a PATH of fakes and a few linked system tools, so a real hyprctl,
# qdbus, calamares or sleep on the machine running the test cannot be consulted.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/packaging/shinobi-installer/usr/lib/shinobi/shinobi-installer-autostart"

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
for tool in sh cat sed tr grep; do
  src="$(command -v "$tool")"
  ln -sf "$src" "$tools/$tool"
done

cat >"$fake/calamares" <<'EOF'
#!/bin/sh
echo started >>"$FAKE_LOG/calamares"
EOF
cat >"$fake/qdbus" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG/qdbus"
exit 1
EOF
cat >"$fake/sleep" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG/sleep"
EOF
cat >"$fake/hyprctl" <<'EOF'
#!/bin/sh
# Answers after FAKE_HYPR_READY_AFTER failed calls; never when it is "never".
n=$(wc -l <"$FAKE_LOG/hyprctl" 2>/dev/null || echo 0)
echo "$*" >>"$FAKE_LOG/hyprctl"
[ "${FAKE_HYPR_READY_AFTER:-0}" = never ] && exit 1
[ "$n" -ge "${FAKE_HYPR_READY_AFTER:-0}" ]
EOF
ln -sf "$(command -v wc)" "$tools/wc"
chmod +x "$fake"/*
export FAKE_LOG="$log"

# run <cmdline> [VAR=value ...]: run the script with that command line; sets rc, out, err.
rc=0
out=""
err=""
run() {
  local cmdline="$1"
  shift
  rm -f "$log"/*
  printf '%s\n' "$cmdline" >"$work/cmdline"
  rc=0
  env -i PATH="$fake:$tools" SHINOBI_CMDLINE_FILE="$work/cmdline" FAKE_LOG="$log" "$@" \
    sh "$SCRIPT" >"$work/out" 2>"$work/err" || rc=$?
  out="$(<"$work/out")"
  err="$(<"$work/err")"
}
count() { if [[ -e "$log/$1" ]]; then wc -l <"$log/$1" | tr -d ' '; else echo 0; fi; }

echo "== only a boot that asked to install starts the wizard =="
run "BOOT_IMAGE=/live/vmlinuz boot=live quiet splash" WAYLAND_DISPLAY=wayland-1
check "an ordinary boot: nothing happens, successfully" "$rc|$(count calamares)|$(count hyprctl)" "0|0|0"
run "boot=live shinobi.installerx" WAYLAND_DISPLAY=wayland-1
check "a parameter that only starts like the marker is not the marker" "$(count calamares)" "0"
run "boot=live xshinobi.installer=1" WAYLAND_DISPLAY=wayland-1
check "nor one that merely contains it" "$(count calamares)" "0"
run "boot=live shinobi.installer=1 quiet" WAYLAND_DISPLAY=wayland-1
check "shinobi.installer=1 starts it" "$rc|$(count calamares)" "0|1"
run "boot=live quiet shinobi.installer" WAYLAND_DISPLAY=wayland-1
check "so does the bare marker" "$rc|$(count calamares)" "0|1"
rc=0
rm -f "$log"/*
env -i PATH="$fake:$tools" SHINOBI_CMDLINE_FILE="$work/no-such-file" FAKE_LOG="$log" WAYLAND_DISPLAY=wayland-1 sh "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "a command line that cannot be read: nothing happens, successfully" "$rc|$(count calamares)" "0|0"

echo "== it waits for the desktop, and means Hyprland by that =="
run "shinobi.installer=1" WAYLAND_DISPLAY=wayland-1 FAKE_HYPR_READY_AFTER=0
check "a desktop that is ready at once: the wizard starts with no waiting" "$rc|$(count calamares)|$(count sleep)" "0|1|0"
check "and without a word to stderr" "$err" ""
check "it asked Hyprland" "$(count hyprctl)" "1"
run "shinobi.installer=1" WAYLAND_DISPLAY=wayland-1 FAKE_HYPR_READY_AFTER=3
check "a desktop ready after three tries: it waited for exactly that" "$rc|$(count calamares)|$(count sleep)|$(count hyprctl)" "0|1|3|4"
check "in half-second steps" "$(sort -u "$log/sleep" | tr '\n' ' ')" "0.5 "
check "and did not claim the desktop never reported ready" "$err" ""
run "shinobi.installer=1" DISPLAY=:0 FAKE_HYPR_READY_AFTER=0
check "X11's DISPLAY counts as a display too" "$(count calamares)" "1"
for var in "WAYLAND_DISPLAY=wayland-1" "DISPLAY=:0"; do
  run "shinobi.installer=1" "$var" FAKE_HYPR_READY_AFTER=never
  check "$var, a desktop that never answers: it still starts the wizard after 30 seconds' worth of waiting" \
    "$rc|$(count calamares)|$(count sleep)" "0|1|59"
  check "$var, and says why it did not wait longer" "$(grep -c 'did not report ready' <<<"$err" || true)" "1"
done
run "shinobi.installer=1" FAKE_HYPR_READY_AFTER=0
check "with no display at all the desktop is not ready, whatever hyprctl says" "$(count calamares)|$(count sleep)|$(count hyprctl)" "1|59|0"
check "KWin is never asked, in any of the above" "$(count qdbus)" "0"

echo "== no wizard to start =="
rm -f "$fake/calamares"
run "shinobi.installer=1" WAYLAND_DISPLAY=wayland-1
check "calamares missing: a failure, with the reason" "$rc|$(grep -c 'calamares is not installed' <<<"$err" || true)" "1|1"
check "and it does not wait around first" "$(count sleep)|$(count hyprctl)" "0|0"

echo
if [[ $failures -eq 0 ]]; then
  echo "installer-autostart-test: PASS ($checks checks)"
else
  echo "installer-autostart-test: FAIL ($failures of $checks checks)"
  exit 1
fi
