#!/usr/bin/env bash
# End to end: boot the image, install it with the Shinobi Installation Wizard the way a
# person would, boot what was installed, log in at the login screen, and check it.
#
# Every other suite checks that the tree is coherent. This one checks that the product
# works, and it is the only place a good deal of the claims are exercised: the wizard
# installs at all, the account it creates can log in, the layer arrived, and -- the
# thing that was wrong for a long time -- the password typed in the wizard is the
# password the login screen and the lock screen read.
#
# How it drives a guest that has no serial login and no ssh:
#   - keys go in through QEMU's monitor, as presses of physical keys (tests/vm-drive.py),
#     translated for the layout under test with the real xkb library, so it types like a
#     person with that keyboard: `SHINOBI_E2E_LAYOUT=de` presses the keys a German keyboard
#     has a Z and a Y on, and the guest reads them through whatever layout it is really on;
#   - commands run in the guest through a small agent over QEMU's network
#     (tests/vm-agent.py on the host, tests/fixtures/guest-agent.sh in the guest), started
#     once by typing a single line into a terminal.
# The wizard's pages are driven from the keyboard, with Alt+N and friends. Pointer input
# does not reach this desktop under QEMU, and xdotool does not work on Wayland, which is
# what an earlier version of this file used.
#
# The assertions that need no guest are in test-vm-harness.sh, which is in run-all.sh. This
# needs an image and KVM and takes about 20 minutes, so it is not; without
# SHINOBI_E2E_ISO it skips with an explanation, because a suite that skips is easy to
# mistake for a suite that ran.
#
#   SHINOBI_E2E_ISO=distro/kali-live/images/shinobi.iso ./tests/test-install-e2e.sh
#   SHINOBI_E2E_LAYOUT=de SHINOBI_E2E_ISO=... ./tests/test-install-e2e.sh
#
# Settings:
#   SHINOBI_E2E_LAYOUT       us (default), de, fr, es, it, pt, nl, se, gb, ru or ua
#   SHINOBI_E2E_WORK         where the run's disk and logs go (default ~/.cache/shinobi-e2e;
#                            not /tmp, which is often a RAM disk with a quota: a 20 GB disk
#                            filled one and made the installer fail with a missing directory)
#   SHINOBI_E2E_KEEP=1       keep the work directory (kept anyway on a failure)
#   SHINOBI_E2E_MENU_DOWN    how many entries to move down the BIOS boot menu to reach
#                            "Install Shinobi OS" (default 5)
#
# Requirements: qemu-system-x86_64, KVM, python3, libxkbcommon0 and xkb-data, curl.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${SHINOBI_E2E_ISO:-}"
LAYOUT="${SHINOBI_E2E_LAYOUT:-us}"
KEEP="${SHINOBI_E2E_KEEP:-0}"
MENU_DOWN="${SHINOBI_E2E_MENU_DOWN:-5}"
DRIVE="$ROOT/tests/vm-drive.py"
SELFTEST="$ROOT/tests/fixtures/shinobi-selftest"
# A throwaway password for a throwaway machine. It is typed as this string on whatever
# keyboard the layout under test has, and has letters (y and z) that move between layouts.
PASSWORD="y7z2q9k4y1z8"

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
section() { printf '\n== %s ==\n' "$1"; }

if [[ -z $ISO ]]; then
  echo "e2e: SKIP (no image. Set SHINOBI_E2E_ISO, or build one with distro/build.sh)"
  echo "e2e:       This suite is the only thing that boots the product; a green"
  echo "e2e:       source suite says the tree is coherent, not that it installs."
  exit 0
fi

# What the wizard's keyboard page calls the layout, to find it in the list by typing, and
# what Hyprland is told for it: the layouts that cannot type ASCII come with us in front.
case "$LAYOUT" in
  us) wizard_name="" ;;
  de) wizard_name="german" ;;
  fr) wizard_name="french" ;;
  es) wizard_name="spanish" ;;
  it) wizard_name="italian" ;;
  pt) wizard_name="portuguese" ;;
  nl) wizard_name="dutch" ;;
  se) wizard_name="swedish" ;;
  gb) wizard_name="english (uk)" ;;
  ru) wizard_name="russian" ;;
  ua) wizard_name="ukrainian" ;;
  *) echo "e2e: FAIL (no wizard name known for layout '$LAYOUT')"; exit 1 ;;
esac
expected_layout="$LAYOUT"
[[ $LAYOUT == ru || $LAYOUT == ua ]] && expected_layout="us,$LAYOUT"

section "the harness can run here"
for need in qemu-system-x86_64 curl python3; do
  command -v "$need" >/dev/null 2>&1 || { echo "e2e: SKIP (no $need)"; exit 0; }
done
if [[ ! -e /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "e2e: SKIP (/dev/kvm unavailable; this needs hardware virtualisation)"
  exit 0
fi
if [[ ! -f $ISO ]]; then
  echo "e2e: FAIL (SHINOBI_E2E_ISO=$ISO does not exist)"
  exit 1
fi
sh -n "$SELFTEST" || { echo "e2e: FAIL (the self-test is not valid shell)"; exit 1; }
if ! python3 -I "$DRIVE" translate --layout "$LAYOUT" "$PASSWORD" >/dev/null 2>&1; then
  echo "e2e: FAIL (cannot type the test password on layout '$LAYOUT': $(python3 -I "$DRIVE" translate --layout "$LAYOUT" "$PASSWORD" 2>&1 | tail -1))"
  exit 1
fi
check "the harness can run here" "yes" "yes"

WORK="${SHINOBI_E2E_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/shinobi-e2e}/run-$$"
mkdir -p "$WORK/serve/live" "$WORK/serve/installed"
cp "$ROOT/tests/fixtures/guest-agent.sh" "$WORK/serve/agent.sh"
cp "$SELFTEST" "$WORK/serve/selftest"
mon_sock="$WORK/mon.sock"
disk="$WORK/target.qcow2"
qemu-img create -f qcow2 "$disk" 24G >/dev/null
qemu_pid=""
server_pid=""

stop_qemu() {
  if [[ -n $qemu_pid ]]; then
    kill "$qemu_pid" 2>/dev/null
    wait "$qemu_pid" 2>/dev/null
    qemu_pid=""
  fi
}
cleanup() {
  stop_qemu
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
  if [[ $KEEP == 0 && $failures == 0 ]]; then
    rm -rf "$WORK"
  else
    echo "e2e: kept $WORK (screenshots and the agent's output are there)"
  fi
}
trap cleanup EXIT

python3 -I "$ROOT/tests/vm-agent.py" "$WORK/serve" >"$WORK/server.out" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do grep -q '^PORT ' "$WORK/server.out" 2>/dev/null && break; sleep 0.1; done
port="$(sed -n 's/^PORT //p' "$WORK/server.out")"
[[ -n $port ]] || { echo "e2e: FAIL (the agent server did not start)"; exit 1; }
host_port="10.0.2.2:$port"

mon() { python3 -I "$DRIVE" --monitor "$mon_sock" "$@"; }
press() { mon keys --gap 0.4 "$@"; }
# typed <layout> <text>: press the keys that type <text> on that layout.
typed() { mon type --layout "$1" --gap 0.08 "$2"; }
shot() { mon shot "$WORK/$1.png" 2>/dev/null; }
die() {
  shot "failed-$1" || true
  printf 'e2e: FAIL at %s\n' "$2"
  check "$2" "no" "yes"
  printf '\ne2e-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
}

start_qemu() {
  # start_qemu <log> <extra qemu args...>
  local log="$1"
  shift
  rm -f "$mon_sock"
  qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 -vga std -display none -no-reboot \
    -monitor "unix:$mon_sock,server,nowait" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 "$@" >"$WORK/$log" 2>&1 &
  qemu_pid=$!
  for _ in $(seq 1 50); do [[ -S $mon_sock ]] && break; sleep 0.1; done
}

agent_n=0
# agent <session> <command> [timeout]: run a command in the guest; prints its output, sets
# agent_rc. The command is queued once; waiting is only for its output to arrive.
agent_session=""
agent() {
  agent_session="$1"
  agent_n=$((agent_n + 1))
  agent_current="$agent_n"
  printf '%s\n' "$2" >"$WORK/serve/$1/cmd.$agent_n.sh"
  agent_wait "$1" "$agent_n" "${3:-60}"
}
agent_wait() {
  local waited=0
  while ((waited < $3)); do
    if [[ -f $WORK/serve/$1/out.$2 ]]; then
      agent_out="$(sed '$d' "$WORK/serve/$1/out.$2")"
      agent_rc="$(sed -n 's/^rc=//p' "$WORK/serve/$1/out.$2" | tail -1)"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  agent_out=""
  agent_rc=""
  return 1
}

# Start the agent by typing one line into a terminal, in the layout the session is on.
# Returns 0 when it answers. The first command queued is the answer it is waited for.
start_agent() {
  local session="$1" layout="$2" timeout="$3"
  agent_n=0
  printf 'echo alive\n' >"$WORK/serve/$session/cmd.1.sh"
  agent_n=1
  press meta_l-ret
  sleep 5
  typed "$layout" "curl -s -o a $host_port/agent.sh; sh a $host_port $session &"
  press ret
  agent_wait "$session" 1 "$timeout"
}

section "installing from the image, as a person would"
start_qemu live.log -cdrom "$ISO" -boot d -drive "file=$disk,if=virtio,format=qcow2"
sleep 15
shot menu
press "down*$MENU_DOWN" ret
# Boot, log in (the live session does that itself), start the wizard from the desktop.
sleep 100
if ! start_agent live us 60; then
  press ctrl-c ctrl-c
  start_agent live us 40 || die live-agent "the live session answers an agent started from a terminal"
fi
check "the live session came up, and answers an agent" "$agent_out" "alive"

agent live 'pkill hypridle; hyprctl dispatch focuswindow class:io.calamares.calamares; pgrep -x calamares >/dev/null && echo wizard-running' 30
check "the wizard started by itself, as root" "$(grep -c 'wizard-running' <<<"$agent_out" || true)" "1"
agent live 'hyprctl devices | grep -m1 rules' 30
check "and Hyprland is on the layout the image was built with" "$(grep -c 'l "us"' <<<"$agent_out" || true)" "1"

section "the keyboard page: the layout chosen reaches the live session"
press alt-n
sleep 5
if [[ -n $wizard_name ]]; then
  press tab tab
  typed us "$wizard_name"
  sleep 4
fi
agent live 'hyprctl devices | grep -m1 rules; hyprctl configerrors' 30
shot keyboard
check "Hyprland, which the wizard runs on, is now on the layout that was chosen ($LAYOUT)" \
  "$(grep -c "l \"$expected_layout\"" <<<"$agent_out" || true)" "1"
check "and has no config error" "$(grep -c -i 'error' <<<"$agent_out" || true)" "0"

section "the rest of the wizard, typed on that layout"
press alt-n
sleep 8
press tab tab tab spc
sleep 3
press alt-n
sleep 5
typed "$LAYOUT" "e2e test"
press tab tab tab
typed "$LAYOUT" "$PASSWORD"
press tab
typed "$LAYOUT" "$PASSWORD"
sleep 2
shot users
press alt-n
sleep 5
press alt-i
sleep 3
press ret
sleep 10
shot installing

section "the install runs to the end"
waited=0
state=RUNNING
while ((waited < ${SHINOBI_E2E_INSTALL_TIMEOUT:-1500})); do
  sleep 20
  waited=$((waited + 20))
  agent live 'f=$(find /home/shinobi/.cache -name session.log 2>/dev/null | head -1); if grep -q "Installation failed" "$f"; then echo FAILED; grep -m3 -E "ERROR|WARNING.*(grub|unpackfs)" "$f"; elif grep -q "Starting job \"umount\"" "$f" && ! mount | grep -q calamares-root; then echo DONE; else echo RUNNING; fi' 30
  state="$(head -1 <<<"$agent_out")"
  [[ $state == DONE || $state == FAILED ]] && break
done
shot installed-page
check "the wizard installed, with no failure" "$state" "DONE"
[[ $state == DONE ]] || { tail -4 <<<"$agent_out"; die install "the install finished"; }

# Power off from inside: the agent does not come back from this, so it is not waited on.
agent_n=$((agent_n + 1))
printf 'sudo poweroff\n' >"$WORK/serve/live/cmd.$agent_n.sh"
for _ in $(seq 1 60); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 1; done
stop_qemu

section "what was installed: the login screen takes the password typed in the wizard"
start_qemu installed.log -drive "file=$disk,if=virtio,format=qcow2"
sleep 75
shot greeter
typed "$LAYOUT" "$PASSWORD"
press ret
sleep 60
shot session
# Which layout is the session on? The line that starts the agent is typed for one layout,
# and it only works if the session reads those key presses the way the typist meant them.
# The layout chosen in the wizard comes first; if only plain us works, the session did not
# follow the system's layout, and that is the bug.
session_on=""
if start_agent installed "$LAYOUT" 40; then
  session_on="$LAYOUT"
else
  press ctrl-c ctrl-c
  if start_agent installed us 40; then session_on="us"; fi
fi
[[ -n $session_on ]] || die session-agent "the login screen accepted the password and the session answers an agent"
check "the login screen accepted the password typed in the wizard (the session started)" "yes" "yes"
check "and the session reads key presses on the layout that was chosen, not on us" "$session_on" "$LAYOUT"

section "the installed system is what was claimed"
agent installed 'hyprctl devices | grep -m1 rules; grep XKBLAYOUT /etc/default/keyboard' 30
check "Hyprland is on the system's layout" "$(grep -c "l \"$expected_layout\"" <<<"$agent_out" || true)" "1"
check "which is what the wizard wrote for the login screen" \
  "$(grep -c "XKBLAYOUT=\"$expected_layout\"" <<<"$agent_out" || true)" "1"

agent installed "curl -sf -o /tmp/selftest http://$host_port/selftest && sh /tmp/selftest" 120
selftest_summary="$(grep -E '^SELFTEST [0-9]+ checks' <<<"$agent_out" | tail -1)"
check "the self-test ran inside the installed system" "$([[ -n $selftest_summary ]] && echo yes || echo no)" "yes"
check "and no assertion in it failed" "$(grep -c '^SELFTEST FAIL' <<<"$agent_out" || true)" "0"
grep '^SELFTEST FAIL' <<<"$agent_out" | sed 's/^/    /'

section "the lock screen takes it too"
agent installed 'nohup hyprlock >/tmp/hyprlock.log 2>&1 & sleep 4; pgrep -x hyprlock >/dev/null && echo LOCKED || echo NOT-LOCKED' 30
check "the screen locks" "$(head -1 <<<"$agent_out")" "LOCKED"
typed "$LAYOUT" "$PASSWORD"
press ret
sleep 5
agent installed 'pgrep -x hyprlock >/dev/null && echo STILL-LOCKED || echo UNLOCKED' 30
shot lock
check "and the same key presses that logged in unlock it" "$(head -1 <<<"$agent_out")" "UNLOCKED"
agent installed 'pkill -USR1 hyprlock; true' 15

agent_n=$((agent_n + 1))
printf 'sudo poweroff\n' >"$WORK/serve/installed/cmd.$agent_n.sh"
for _ in $(seq 1 60); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 1; done
stop_qemu

printf '\n'
if ((failures > 0)); then
  printf 'e2e-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ne2e-test: PASS (layout %s)\n' "$checks" "$checks" "$LAYOUT"
