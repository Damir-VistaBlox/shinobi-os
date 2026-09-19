#!/usr/bin/env bash
# Wrapper around kali-live's build.sh: stages our variant config and the
# shinobi CLI/MCP-server source into the kali-live submodule checkout, then
# delegates to its build.sh. Must run on a Debian/Kali-family host with
# live-build installed (see kali-live/README.md) — this doesn't work from an
# Arch host.
#
# SHINOBI_VARIANT picks which of overlay/kali-config/variant-* to build:
#   shinobi      (default) — full Hyprland desktop
#   shinobi-min  — console only, no desktop at all. Build this one first: it
#                 proves the shinobi CLI + shinobi-recon MCP server bake
#                 correctly into a real Kali image with far less that can go
#                 wrong than the desktop variant (no font download, no SDDM
#                 theme detection, ~40 fewer packages). See DESIGN.md.
#
# Example: SHINOBI_VARIANT=shinobi-min ./distro/build.sh --verbose
#
# NOTE: this rsyncs into the submodule's shared kali-config/common/includes.chroot,
# so treat this checkout of kali-live as dedicated to building shinobi variants.
# Building a stock Kali variant (e.g. --variant xfce) from this same checkout
# after running this script will carry shinobi's files along for the ride —
# use a separate clean checkout of kali-live for that.
set -euo pipefail

SHINOBI_VARIANT="${SHINOBI_VARIANT:-shinobi}"
SHINOBI_SQUASHFS_COMPRESSION="${SHINOBI_SQUASHFS_COMPRESSION:-zstd}"
SHINOBI_SQUASHFS_LEVEL="${SHINOBI_SQUASHFS_LEVEL:-3}"
export SHINOBI_SQUASHFS_COMPRESSION SHINOBI_SQUASHFS_LEVEL
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO_DIR="$ROOT/distro"
SUBMODULE="$DISTRO_DIR/kali-live"
OVERLAY="$DISTRO_DIR/overlay"
BOOTLOADER_OVERLAY="$OVERLAY/bootloaders"

if [[ ! -d "$OVERLAY/kali-config/variant-$SHINOBI_VARIANT" ]]; then
  echo "shinobi: no such variant '$SHINOBI_VARIANT' at $OVERLAY/kali-config/variant-$SHINOBI_VARIANT" >&2
  exit 1
fi

if [[ ! -f "$SUBMODULE/build.sh" ]]; then
  echo "shinobi: $SUBMODULE is empty. Run: git submodule update --init" >&2
  exit 1
fi

echo "== Staging shinobi CLI + MCP server into the overlay (generated, not committed) =="
STAGE="$OVERLAY/includes.chroot/opt/shinobi"
rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -a "$ROOT/bin" "$ROOT/libexec" "$ROOT/mcp-servers" "$ROOT/themes" "$ROOT/packaging" "$STAGE/"

echo "== Linking variant-$SHINOBI_VARIANT into the kali-live checkout =="
ln -sfn "$OVERLAY/kali-config/variant-$SHINOBI_VARIANT" "$SUBMODULE/kali-config/variant-$SHINOBI_VARIANT"

echo "== Merging overlay includes.chroot into kali-live's common includes.chroot =="
COMMON_INCLUDES="$SUBMODULE/kali-config/common/includes.chroot"
mkdir -p "$COMMON_INCLUDES"

# The kali-live checkout is deliberately reused between builds.  Remove only
# paths owned by this project before copying the current overlay, so files we
# have retired (for example the former Waybar service) cannot remain in a new
# ISO.  Do not use rsync --delete here: common/includes.chroot also contains
# Kali's own live-build files.
for staged_path in \
  "$COMMON_INCLUDES/opt/shinobi" \
  "$COMMON_INCLUDES/opt/kaliai" \
  "$COMMON_INCLUDES/usr/share/shinobi-dotfiles" \
  "$COMMON_INCLUDES/usr/share/kaliai-dotfiles" \
  "$COMMON_INCLUDES/usr/share/shinobi" \
  "$COMMON_INCLUDES/usr/share/kaliai" \
  "$COMMON_INCLUDES/usr/share/backgrounds/shinobi-os" \
  "$COMMON_INCLUDES/usr/local/bin/shinobi-session" \
  "$COMMON_INCLUDES/usr/local/bin/shinobi-welcome" \
  "$COMMON_INCLUDES/usr/local/bin/shinobi-waybar-engagement" \
  "$COMMON_INCLUDES/usr/local/bin/kaliai-waybar-engagement" \
  "$COMMON_INCLUDES/etc/systemd/user/shinobi-shell.service" \
  "$COMMON_INCLUDES/etc/systemd/user/shinobi-waybar.service" \
  "$COMMON_INCLUDES/etc/xdg/xdg-desktop-portal/hyprland-portals.conf"
do
  rm -rf -- "$staged_path"
done

rsync -a "$OVERLAY/includes.chroot/" "$COMMON_INCLUDES/"

if [[ -d "$BOOTLOADER_OVERLAY" ]]; then
  echo "== Applying Shinobi bootloader theme overlay =="
  rsync -a "$BOOTLOADER_OVERLAY/" "$SUBMODULE/kali-config/common/"
fi

# Kali's outer build wrapper accepts only Kali-specific flags, so live-build
# options must be staged into auto/config rather than forwarded on its CLI.
# Keep this local to the dedicated staged checkout; the vendored source remains
# unmodified in git.
AUTO_CONFIG="$SUBMODULE/auto/config"
if ! grep -q '^[[:space:]]*--chroot-squashfs-compression-type ' "$AUTO_CONFIG"; then
  awk -v compression="$SHINOBI_SQUASHFS_COMPRESSION" -v level="$SHINOBI_SQUASHFS_LEVEL" '
    /^[[:space:]]*--bootappend-live / && !inserted {
      printf "  --chroot-squashfs-compression-type \"%s\" \\\n", compression
      printf "  --chroot-squashfs-compression-level \"%s\" \\\n", level
      inserted = 1
    }
    { print }
  ' "$AUTO_CONFIG" >"$AUTO_CONFIG.shinobi"
  chmod --reference="$AUTO_CONFIG" "$AUTO_CONFIG.shinobi"
  mv "$AUTO_CONFIG.shinobi" "$AUTO_CONFIG"
fi

echo "== Building (variant $SHINOBI_VARIANT; SquashFS $SHINOBI_SQUASHFS_COMPRESSION level $SHINOBI_SQUASHFS_LEVEL) =="
cd "$SUBMODULE"
exec ./build.sh --variant "$SHINOBI_VARIANT" "$@"
