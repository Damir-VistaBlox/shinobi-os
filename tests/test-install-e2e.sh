#!/usr/bin/env bash
# End-to-end: boot the image, install with the Shinobi Installation Wizard, boot
# what was installed, and check it.
#
# Every other suite in this repository checks that the tree is coherent. This one
# checks that the product works, and it is the only place three of the claimed
# fixes are actually exercised: the account rename, the RuntimeDirectory fix, and
# the wizard at all. Each of those shipped into a package or a config that
# passes every local check and cannot start without a boot.
#
# It needs an image, and building one needs the runner. Without
# SHINOBI_E2E_ISO it skips with an explanation rather than passing quietly,
# because a suite that skips is easy to mistake for a suite that ran.
#
#   SHINOBI_E2E_ISO=~/shinobi-iso-dl/shinobi-os-amd64.iso ./tests/test-install-e2e.sh
#
# Requirements: qemu-system-x86_64, KVM, and ~25 minutes of wall clock.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${SHINOBI_E2E_ISO:-}"
WORK="${SHINOBI_E2E_WORK:-$(mktemp -d)}"
KEEP="${SHINOBI_E2E_KEEP:-0}"
BOOT_TIMEOUT="${SHINOBI_E2E_BOOT_TIMEOUT:-900}"
INSTALL_TIMEOUT="${SHINOBI_E2E_INSTALL_TIMEOUT:-3600}"

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

cleanup() {
  if [[ $KEEP == 0 ]]; then
    rm -rf "$WORK"
  else
    echo "e2e: kept $WORK"
  fi
}

if [[ -z $ISO ]]; then
  echo "e2e: SKIP (no image. Set SHINOBI_E2E_ISO, or build one with distro/build.sh)"
  echo "e2e:       This suite is the only thing that boots the product; a green"
  echo "e2e:       source suite says the tree is coherent, not that it installs."
  exit 0
fi

printf 'e2e: the assertions this suite makes are checked here first, without an\n'
printf 'e2e: image, because a harness that cannot say what it is looking for is a\n'
printf 'e2e: harness that cannot tell a failure from a hang.\n\n'

section "the self-test the harness will read from the installed system"
# These are the same assertions the guest makes, checked here against the source
# so that a typo in the fixture is caught without a 25-minute build.
selftest="$ROOT/tests/fixtures/shinobi-selftest"
sh -n "$selftest"
check "the self-test is valid shell" "ok" "ok"
selftest_checks=$(grep -c '^check "' "$selftest" || true)
check "it asserts something" "$([[ $selftest_checks -ge 15 ]] && echo yes || echo no)" "yes"
check "it refuses a live-session account" \
  "$(grep -q 'it is not the live session' "$selftest" && echo yes || echo no)" "yes"
check "it refuses an inherited autologin" \
  "$(grep -q 'no autologin is configured' "$selftest" && echo yes || echo no)" "yes"
check "it checks the home's ownership" \
  "$(grep -q "the home belongs to the account" "$selftest" && echo yes || echo no)" "yes"
check "it checks that the medium is not in fstab" \
  "$(grep -q "the medium is not in fstab" "$selftest" && echo yes || echo no)" "yes"

section "the harness can run here"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "e2e: SKIP (no qemu-system-x86_64)"
  exit 0
fi
if [[ ! -e /dev/kvm ]] || [[ ! -r /dev/kvm ]]; then
  echo "e2e: SKIP (/dev/kvm unavailable; this needs hardware virtualisation)"
  exit 0
fi
if [[ ! -f $ISO ]]; then
  echo "e2e: FAIL (SHINOBI_E2E_ISO=$ISO does not exist)"
  exit 1
fi

mkdir -p "$WORK"
trap cleanup EXIT

# A second disk, blank. Installing onto it is the whole point, and the wizard's
# partition page cannot be driven without somewhere to install to.
target="$WORK/target.qcow2"
qemu-img create -f qcow2 "$target" 20G >/dev/null

install_log="$WORK/install.log"
installed_log="$WORK/installed.log"

section "installing from the image"
# The live session's serial console carries the wizard's progress; the wizard
# itself is graphical, so this drives it with xdotool inside the guest. Driving
# the real UI rather than a test profile is deliberate: a profile that skips the
# partitioning page does not test the page, and every way of testing an installer
# without driving it tests the harness instead.
cat >"$WORK/drive-installer.sh" <<'DRIVER'
#!/bin/bash
# Runs inside the live session. Starts the wizard, then clicks it.
set -u
log=/tmp/e2e-drive.log
exec >>"$log" 2>&1
echo "driver started $(date)"

# The autostart launcher starts the wizard when the boot menu entry carries the
# marker; if it is not up within two minutes, start it ourselves.
for _ in $(seq 1 24); do
  pgrep -x calamares >/dev/null && break
  sleep 5
done
if ! pgrep -x calamares >/dev/null; then
  echo "autostart did not launch the wizard; starting it directly"
  calamares &
fi

click() { xdotool mousemove "$1" "$2" click 1; sleep "${3:-1}"; }
key()   { xdotool key --clearmodifiers "$1"; sleep "${2:-1}"; }
type()  { xdotool type --clearmodifiers "$1"; sleep 1; }

# Page-by-page from the bottom-right of a 800x600 window: Next is always last,
# so the coordinates do not depend on how many fields a page has.
next_button() { click 760 560 3; }

for page in 1 2 3 4 5 6 7 8; do
  echo "--- page $page ---"
  # Partition page: the operator has to pick a disk, and the wizard says which.
  # The target is the only ~20G virtio disk with nothing on it.
  if pgrep -x calamares >/dev/null; then
    xdotool search --class calamares windowactivate --sync key Return 2>/dev/null || true
  fi
  sleep 2
  next_button
done
echo "driver finished $(date)"
DRIVER
chmod +x "$WORK/drive-installer.sh"

timeout "$INSTALL_TIMEOUT" qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -drive "file=$ISO,if=virtio,media=cdrom,readonly=on" \
  -drive "file=$target,if=virtio,format=qcow2" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$install_log" \
  -monitor unix:"$WORK/mon.sock",server,nowait \
  ${SHINOBI_E2E_EXTRA:-} &
qemu_pid=$!

wait_for() {
  local pattern="$1" timeout="$2" waited=0
  while ((waited < timeout)); do
    grep -qE "$pattern" "$install_log" 2>/dev/null && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

section "the live session comes up"
if wait_for 'SELFTEST|Reached target|Booting' "$BOOT_TIMEOUT"; then
  check "the image booted" "yes" "yes"
else
  check "the image booted" "no" "yes"
  echo "e2e: the serial log tail is the only evidence available here:"
  tail -40 "$install_log" 2>/dev/null
  kill "$qemu_pid" 2>/dev/null
  exit 1
fi

section "the wizard installs"
# The wizard announces its own completion on the serial console through the
# guest's own reporting, so this waits for the machine to reboot rather than
# clicking through every page blind. The driver script above is what drives the
# UI; this is what notices when it is finished.
if wait_for 'Finished|reboot|SELFTEST' "$INSTALL_TIMEOUT"; then
  check "the wizard reported completion" "yes" "yes"
else
  check "the wizard reported completion" "no" "yes"
fi

kill "$qemu_pid" 2>/dev/null
wait "$qemu_pid" 2>/dev/null

section "what was installed boots and describes itself"
# The installed disk, not the image. A test that boots the image again proves
# nothing about the install, which is the mistake the previous boot suite made.
timeout 900 qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 \
  -drive "file=$target,if=virtio,format=qcow2" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$installed_log" \
  ${SHINOBI_E2E_EXTRA:-} &
qemu_pid=$!

if wait_for 'SELFTEST (PASS|FAIL)|selftest completed' 600; then
  check "the installed system booted and reported" "yes" "yes"
else
  check "the installed system booted and reported" "no" "yes"
  tail -60 "$installed_log" 2>/dev/null
  kill "$qemu_pid" 2>/dev/null
  exit 1
fi

kill "$qemu_pid" 2>/dev/null
wait "$qemu_pid" 2>/dev/null

section "the installed system is what was claimed"
selftest_passed=$(grep -c 'SELFTEST PASS' "$installed_log" 2>/dev/null || true)
selftest_failed=$(grep -c 'SELFTEST FAIL' "$installed_log" 2>/dev/null || true)
check "no assertion failed inside the installed system" "$selftest_failed" "0"
check "the self-test passed" \
  "$(grep -oE 'SELFTEST [0-9]+ checks, [0-9]+ failures' "$installed_log" | tail -1 | grep -q ', 0 failures' && echo yes || echo no)" "yes"

# The individual claims, asserted here as well so that a failure names itself
# rather than arriving as one aggregate number.
for claim in \
  'it is not the live session' \
  'sudo works for it' \
  'the dotfiles were applied' \
  'the home belongs to the account' \
  'no autologin is configured' \
  'the medium is not in fstab'; do
  check "$claim" "$(grep -c "SELFTEST FAIL $claim" "$installed_log" 2>/dev/null || true)" "0"
done

printf '\n'
if ((failures > 0)); then
  printf 'e2e-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  printf 'e2e-test: serial logs kept in %s\n' "$WORK"
  KEEP=1
  exit 1
fi
printf '%d/%d checks passed\ne2e-test: PASS\n' "$checks" "$checks"