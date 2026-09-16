#!/usr/bin/env bash
set -euo pipefail

ISO="${1:?usage: $0 path/to/shinobi.iso}"
[[ -s "$ISO" ]] || { echo "iso-test: ISO is missing or empty: $ISO" >&2; exit 1; }

command -v xorriso >/dev/null 2>&1 || { echo "iso-test: xorriso is required" >&2; exit 1; }

echo "== ISO metadata =="
report="$(mktemp)"
trap 'rm -f "$report"' EXIT
xorriso -indev "$ISO" -report_el_torito plain | tee "$report"

grep -Eqi 'El Torito|Boot catalog|boot image' "$report" || {
  echo "iso-test: no El Torito boot record found" >&2
  exit 1
}

echo "== ISO boot files =="
listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT
xorriso -indev "$ISO" -find / -type f -print >"$listing"
grep -Eqi '/(isolinux|syslinux)/.*(isolinux|menu|ldlinux)|/EFI/BOOT/.*(BOOT|grub)' "$listing" \
  || { echo "iso-test: expected BIOS/UEFI boot files not found" >&2; exit 1; }

echo "iso-structure-test: PASS"
