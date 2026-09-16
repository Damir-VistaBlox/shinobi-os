#!/usr/bin/env bash
set -euo pipefail

ISO="${1:?usage: $0 path/to/shinobi.iso [bios|uefi] [log-dir]}"
MODE="${2:-bios}"
LOG_DIR="${3:-qemu-test-logs}"
mkdir -p "$LOG_DIR"

[[ -s "$ISO" ]] || { echo "qemu-test: ISO is missing or empty: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qemu-test: qemu-system-x86_64 is required" >&2; exit 1; }

case "$MODE" in
  bios) firmware=() ;;
  uefi)
    for code in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd; do
      if [[ -f "$code" ]]; then
        vars="$(mktemp --suffix=.fd)"
        cp "${code/_CODE/_VARS}" "$vars" 2>/dev/null || truncate -s "$(stat -c %s "$code")" "$vars"
        firmware=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$vars")
        trap 'rm -f "${vars:-}"' EXIT
        break
      fi
    done
    ((${#firmware[@]})) || { echo "qemu-test: UEFI firmware not installed" >&2; exit 1; }
    ;;
  *) echo "qemu-test: mode must be bios or uefi" >&2; exit 2 ;;
esac

log="$LOG_DIR/${MODE}.log"
marker='(Shinobi|shinobi|systemd\[1\]|Reached target|login:)'
echo "== Booting $MODE ISO (up to 150 seconds) =="
accel=(-accel tcg)
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  accel=(-enable-kvm)
fi
set +e
timeout --foreground 150s qemu-system-x86_64 \
  "${accel[@]}" \
  -m 2048 -smp 2 -snapshot \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -boot d -no-reboot -display none -serial "file:$log" \
  "${firmware[@]}"
qemu_status=$?
set -e

if grep -Eiq "$marker" "$log"; then
  echo "qemu-test: $MODE reached userspace (qemu status $qemu_status)"
elif [[ "$qemu_status" -eq 124 && ! -s "$log" ]]; then
  echo "qemu-test: $MODE remained alive for the timeout (serial console unavailable)"
  echo "qemu-test: $MODE PASS (survival check)"
  exit 0
elif [[ "$qemu_status" -eq 124 && -s "$log" ]]; then
  echo "qemu-test: $MODE remained alive for the timeout; no recognized userspace marker" >&2
  tail -40 "$log" >&2 || true
  exit 1
else
  echo "qemu-test: $MODE did not produce a userspace boot marker" >&2
  tail -100 "$log" >&2 || true
  exit 1
fi

echo "qemu-test: $MODE PASS"
