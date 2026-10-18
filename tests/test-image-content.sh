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

tmp_root="${RUNNER_TEMP:-${TMPDIR:-$PWD}}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/shinobi-image-content.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "== Locating live SquashFS =="
# `-print` is not supported by the xorriso version on the self-hosted runner.
# `lsdl` is portable; extract the quoted ISO path from its long listing.
squash_path=$(xorriso -indev "$ISO" -find / -type f -name filesystem.squashfs -exec lsdl 2>/dev/null \
  | awk -F"'" '/filesystem\.squashfs/ { print $2; exit }')
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
  /usr/bin/shinobi \
  /usr/bin/shinobi-version \
  /usr/bin/shinobi-config \
  /usr/bin/Hyprland \
  /usr/bin/quickshell \
  /usr/bin/btop \
  /usr/local/bin/top \
  /usr/lib/shinobi/shinobi-migrate \
  /usr/lib/systemd/user/shinobi-migrate.service \
  /usr/lib/systemd/user/shinobi-desktop.target \
  /usr/lib/systemd/user/shinobi-shell.service \
  /usr/share/plymouth/themes/shinobi/shinobi.script \
  /usr/lib/grub/i386-pc/modinfo.sh \
  /usr/lib/grub/x86_64-efi/modinfo.sh \
  /usr/sbin/mkfs.fat \
  /usr/share/shinobi-dotfiles/etc/skel/.config/hypr/colors.conf
do
  grep -Fq "squashfs-root$path" "$listing" || {
    echo "image-test: missing image path: $path" >&2
    exit 1
  }
done

echo "== Checking package database policy =="
status="$tmp/status"
unsquashfs -cat "$tmp/filesystem.squashfs" /var/lib/dpkg/status >"$status"
for package in kali-linux-core hyprland sddm quickshell btop pipewire wireplumber grub-pc-bin grub-efi-amd64-bin dosfstools ntfs-3g; do
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
# grub-pc and grub-efi-amd64 Conflict with each other and own /etc/default/grub through
# their postinst scripts: the image carries the -bin packages and Calamares runs
# grub-install itself. No signed chain can exist (there is no signed Kali kernel).
for package in kali-linux-default kali-desktop-live grub-pc grub-efi-amd64 grub-efi-amd64-signed shim-signed; do
  # Only a package that is installed counts: a removed-but-not-purged one has a
  # stanza with `Status: deinstall ok config-files` and is not on the image.
  if awk -v package="$package" '
      $1 == "Package:" { found = ($2 == package) }
      found && $0 == "Status: install ok installed" { ok = 1 }
      END { exit(ok ? 0 : 1) }
    ' "$status"; then
    echo "image-test: package unexpectedly installed: $package" >&2
    exit 1
  fi
done

echo "== Checking the installer's configuration against what the image can do =="
# The wizard offers encryption and LVM only if the image can do them: a box that the
# image cannot honour wipes the disk and then fails. Read from this image's own
# /etc/calamares, not the checkout, so the verdict is about what the ISO contains.
partition_conf="$tmp/partition.conf"
unsquashfs -cat "$tmp/filesystem.squashfs" /etc/calamares/modules/partition.conf >"$partition_conf" 2>/dev/null \
  || { echo "image-test: no /etc/calamares/modules/partition.conf in the image" >&2; exit 1; }
package_installed() {
  awk -v package="$1" '
    $1 == "Package:" { found = ($2 == package) }
    found && $0 == "Status: install ok installed" { ok = 1 }
    END { exit(ok ? 0 : 1) }
  ' "$status"
}
conf_lines="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$partition_conf")"
if ! grep -qE '^enableLuksAutomatedPartitioning:[[:space:]]*false' <<<"$conf_lines"; then
  for package in cryptsetup-bin cryptsetup-initramfs; do
    package_installed "$package" || {
      echo "image-test: the wizard offers encryption (partition.conf does not turn it off) but $package is not installed" >&2
      exit 1
    }
  done
fi
if awk '/^lvm:/ {l=1; next} /^[^[:space:]]/ {l=0} l && /^[[:space:]]+enable:[[:space:]]*true/ {f=1} END {exit(f ? 0 : 1)}' <<<"$conf_lines"; then
  package_installed lvm2 || {
    echo "image-test: the wizard offers LVM (partition.conf lvm: enable: true) but lvm2 is not installed" >&2
    exit 1
  }
fi
# BIOS+GPT with no BIOS Boot Partition is what a forced GPT table produces on BIOS firmware.
if grep -qE '^defaultPartitionTableType:[[:space:]]*gpt' <<<"$conf_lines"; then
  echo "image-test: partition.conf forces GPT on BIOS firmware, where GRUB then has no BIOS Boot Partition to embed in" >&2
  exit 1
fi

echo "== Checking top-to-btop compatibility wrapper =="
unsquashfs -cat "$tmp/filesystem.squashfs" /usr/local/bin/top | grep -Fq '/usr/bin/btop' \
  || { echo "image-test: top wrapper does not target btop" >&2; exit 1; }

echo "image-content-test: PASS"
