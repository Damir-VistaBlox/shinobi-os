#!/usr/bin/env bash
set -euo pipefail

ISO="${1:?usage: $0 path/to/shinobi.iso}"
[[ -s "$ISO" ]] || { echo "iso-test: ISO is missing or empty: $ISO" >&2; exit 1; }

command -v xorriso >/dev/null 2>&1 || { echo "iso-test: xorriso is required" >&2; exit 1; }

echo "== ISO metadata =="
report="$(mktemp)"
listing=""
cleanup() { rm -f "$report" "${listing:-}"; }
trap cleanup EXIT
xorriso -indev "$ISO" -report_el_torito plain | tee "$report"

grep -Eqi 'El Torito|Boot catalog|boot image' "$report" || {
  echo "iso-test: no El Torito boot record found" >&2
  exit 1
}

echo "== Boot menus carry no unsubstituted placeholder =="
# live-build fills @LINUX@, @INITRD@, @APPEND_LIVE@ and friends into the boot menu
# files it generates from its templates, and only those. A placeholder in an overlay
# file that is not one of them ships literally. For the BIOS "Install Shinobi OS"
# entries that meant `linux @LINUX@`, a kernel syslinux cannot find, and an entry that
# silently returned to the menu: found by booting the image, not by any test.
menus="$(mktemp -d)"
xorriso -osirrox on -indev "$ISO" -extract /isolinux "$menus/isolinux" >/dev/null 2>&1 || true
xorriso -osirrox on -indev "$ISO" -extract /boot/grub "$menus/grub" >/dev/null 2>&1 || true
# Comment lines are skipped: shinobi-installer.cfg explains the bug by naming the
# placeholders, and a comment is not read by syslinux or GRUB.
leftover="$(grep -rnE '@[A-Z][A-Z_]*@' "$menus" --include='*.cfg' 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
rm -rf "$menus"
if [[ -n "$leftover" ]]; then
  echo "iso-test: a boot menu in the ISO still contains a placeholder:" >&2
  printf '%s\n' "$leftover" | sed 's/^/  /' >&2
  exit 1
fi
echo "no placeholder left in the BIOS or UEFI menus"

echo "== The image names itself, in the places it is read =="
# The volume id is what a file manager calls the medium; it said "Kali Live". It sits in the
# ISO 9660 primary volume descriptor, 40 bytes into the sector at 0x8000, 32 bytes wide.
volume_id="$(python3 -I - "$ISO" <<'PYIN'
import sys
with open(sys.argv[1], "rb") as iso:
    iso.seek(0x8000)
    descriptor = iso.read(2048)
print(descriptor[40:72].decode("ascii", "replace").strip() if descriptor[1:6] == b"CD001" else "(no volume descriptor)")
PYIN
)"
if [[ $volume_id == "Shinobi OS Live" ]]; then
  echo "volume id: $volume_id"
else
  echo "iso-test: the volume id is '$volume_id', not 'Shinobi OS Live'" >&2
  exit 1
fi
# The BIOS live entries come from Kali's template unless an overlay replaces it; two of its
# entries named the account `kali` on the command line, which beats the image's own setting.
entries="$(mktemp -d)"
xorriso -osirrox on -indev "$ISO" -extract /isolinux/live.cfg "$entries/live.cfg" >/dev/null 2>&1 || true
if [[ ! -s $entries/live.cfg ]]; then
  echo "iso-test: could not read /isolinux/live.cfg out of the ISO" >&2
  rm -rf "$entries"
  exit 1
fi
# Comment lines are skipped: the file explains the problem by naming it, and syslinux does not
# read a comment.
if grep -vE '^[[:space:]]*#' "$entries/live.cfg" | grep -qiE 'username=kali|hostname=kali|kali\.org'; then
  echo "iso-test: a BIOS live entry still names Kali:" >&2
  grep -vE '^[[:space:]]*#' "$entries/live.cfg" | grep -niE 'username=kali|hostname=kali|kali\.org' | sed 's/^/  /' >&2
  rm -rf "$entries"
  exit 1
fi
rm -rf "$entries"
echo "no BIOS live entry names Kali"

echo "== ISO boot files =="
listing="$(mktemp)"
# `-print` is not a portable xorriso find action. `lsdl` is supported by the
# runner's xorriso versions and includes each matched ISO path in its output.
xorriso -indev "$ISO" -find / -type f -exec lsdl >"$listing"
grep -Eqi '/(isolinux|syslinux)/.*(isolinux|menu|ldlinux)' "$listing" \
  || { echo "iso-test: BIOS boot files not found" >&2; exit 1; }
grep -Eqi '/EFI/BOOT/.*(BOOT|grub)' "$listing" \
  || { echo "iso-test: UEFI boot files not found" >&2; exit 1; }
grep -Eqi '/(isolinux|syslinux)/.*(shinobi|menu)' "$listing" \
  || { echo "iso-test: Shinobi BIOS menu overlay not found" >&2; exit 1; }
grep -Eqi '/EFI/BOOT/.*(shinobi|theme|grub)' "$listing" \
  || { echo "iso-test: Shinobi UEFI theme files not found" >&2; exit 1; }

echo "iso-structure-test: PASS"
