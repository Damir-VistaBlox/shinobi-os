#!/usr/bin/env bash
# Wrapper around kali-live's build.sh: stages our variant config and the
# kaliai CLI/MCP-server source into the kali-live submodule checkout, then
# delegates to its build.sh. Must run on a Debian/Kali-family host with
# live-build installed (see kali-live/README.md) — this doesn't work from an
# Arch host.
#
# KALIAI_VARIANT picks which of overlay/kali-config/variant-* to build:
#   kaliai      (default) — full Hyprland desktop
#   kaliai-min  — console only, no desktop at all. Build this one first: it
#                 proves the kaliai CLI + kaliai-recon MCP server bake
#                 correctly into a real Kali image with far less that can go
#                 wrong than the desktop variant (no font download, no SDDM
#                 theme detection, ~40 fewer packages). See DESIGN.md.
#
# Example: KALIAI_VARIANT=kaliai-min ./distro/build.sh --verbose
#
# NOTE: this rsyncs into the submodule's shared kali-config/common/includes.chroot,
# so treat this checkout of kali-live as dedicated to building kaliai variants.
# Building a stock Kali variant (e.g. --variant xfce) from this same checkout
# after running this script will carry kaliai's files along for the ride —
# use a separate clean checkout of kali-live for that.
set -euo pipefail

KALIAI_VARIANT="${KALIAI_VARIANT:-kaliai}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO_DIR="$ROOT/distro"
SUBMODULE="$DISTRO_DIR/kali-live"
OVERLAY="$DISTRO_DIR/overlay"

if [[ ! -d "$OVERLAY/kali-config/variant-$KALIAI_VARIANT" ]]; then
  echo "kaliai: no such variant '$KALIAI_VARIANT' at $OVERLAY/kali-config/variant-$KALIAI_VARIANT" >&2
  exit 1
fi

if [[ ! -f "$SUBMODULE/build.sh" ]]; then
  echo "kaliai: $SUBMODULE is empty. Run: git submodule update --init" >&2
  exit 1
fi

echo "== Staging kaliai CLI + MCP server into the overlay (generated, not committed) =="
STAGE="$OVERLAY/includes.chroot/opt/kaliai"
rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -a "$ROOT/bin" "$ROOT/mcp-servers" "$ROOT/themes" "$STAGE/"

echo "== Linking variant-$KALIAI_VARIANT into the kali-live checkout =="
ln -sfn "$OVERLAY/kali-config/variant-$KALIAI_VARIANT" "$SUBMODULE/kali-config/variant-$KALIAI_VARIANT"

echo "== Merging overlay includes.chroot into kali-live's common includes.chroot =="
mkdir -p "$SUBMODULE/kali-config/common/includes.chroot"
rsync -a "$OVERLAY/includes.chroot/" "$SUBMODULE/kali-config/common/includes.chroot/"

echo "== Building (delegating to kali-live/build.sh --variant $KALIAI_VARIANT) =="
cd "$SUBMODULE"
exec ./build.sh --variant "$KALIAI_VARIANT" "$@"
