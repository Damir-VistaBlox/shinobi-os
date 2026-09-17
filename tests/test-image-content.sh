#!/usr/bin/env bash
set -euo pipefail

ISO="${1:?usage: $0 path/to/shinobi.iso}"
[[ -s "$ISO" ]] || { echo "image-test: ISO is missing or empty: $ISO" >&2; exit 1; }
for tool in xorriso unsquashfs; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "image-test: required tool unavailable: $tool" >&2
    exit 1
  }
done

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "== Locating live SquashFS =="
squash_path="$(xorriso -indev "$ISO" -find / -type f -name filesystem.squashfs -print 2>/dev/null | head -n1)"
[[ -n "$squash_path" ]] || { echo "image-test: filesystem.squashfs not found in ISO" >&2; exit 1; }
xorriso -osirrox on -indev "$ISO" -extract "$squash_path" "$tmp/filesystem.squashfs" >/dev/null
[[ -s "$tmp/filesystem.squashfs" ]] || { echo "image-test: failed to extract SquashFS" >&2; exit 1; }

echo "== Checking SquashFS format =="
summary="$(unsquashfs -s "$tmp/filesystem.squashfs")"
grep -Eqi 'Compression.*zstd' <<<"$summary" || {
  echo "image-test: expected zstd SquashFS compression" >&2
  printf '%s\n' "$summary" >&2
  exit 1
}

echo "== Checking installed Shinobi files =="
listing="$tmp/listing"
unsquashfs -ll "$tmp/filesystem.squashfs" >"$listing"
for path in \
  /usr/bin/hyprland \
  /usr/bin/quickshell \
  /usr/bin/btop \
  /usr/local/bin/top \
  /usr/lib/shinobi/shinobi-migrate \
  /usr/lib/systemd/user/shinobi-migrate.service \
  /usr/lib/systemd/user/shinobi-shell.service \
  /usr/share/plymouth/themes/shinobi/shinobi.script \
  /usr/share/shinobi-dotfiles/etc/skel/.config/hypr/colors.conf
do
  grep -Fq " $path" "$listing" || { echo "image-test: missing image path: $path" >&2; exit 1; }
done

echo "== Checking package database policy =="
status="$tmp/status"
unsquashfs -cat "$tmp/filesystem.squashfs" /var/lib/dpkg/status >"$status"
for package in kali-linux-core hyprland sddm quickshell btop pipewire wireplumber; do
  awk -v package="$package" '
    $1 == "Package:" { found = ($2 == package) }
    found && $0 == "Status: install ok installed" { ok = 1 }
    END { exit(ok ? 0 : 1) }
  ' "$status" || { echo "image-test: package not installed: $package" >&2; exit 1; }
done
awk -v package="shinobi-core" '
  $1 == "Package:" { found = ($2 == package) }
  found && $1 == "Maintainer:" { ok = 1 }
  END { exit(ok ? 0 : 1) }
' "$status" || { echo "image-test: shinobi-core Maintainer metadata missing" >&2; exit 1; }
for package in kali-linux-default kali-desktop-live; do
  if awk -v package="$package" '$1 == "Package:" && $2 == package { found = 1 } END { exit(found ? 0 : 1) }' "$status"; then
    echo "image-test: deferred package unexpectedly installed: $package" >&2
    exit 1
  fi
done

echo "== Checking top-to-btop compatibility wrapper =="
unsquashfs -cat "$tmp/filesystem.squashfs" /usr/local/bin/top | grep -Fq '/usr/bin/btop' \
  || { echo "image-test: top wrapper does not target btop" >&2; exit 1; }

echo "image-content-test: PASS"
