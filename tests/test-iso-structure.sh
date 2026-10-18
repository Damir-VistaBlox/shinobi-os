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
leftover="$(grep -rnE '@[A-Z][A-Z_]*@' "$menus" --include='*.cfg' 2>/dev/null || true)"
rm -rf "$menus"
if [[ -n "$leftover" ]]; then
  echo "iso-test: a boot menu in the ISO still contains a placeholder:" >&2
  printf '%s\n' "$leftover" | sed 's/^/  /' >&2
  exit 1
fi
echo "no placeholder left in the BIOS or UEFI menus"

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
