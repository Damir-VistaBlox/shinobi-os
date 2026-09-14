#!/usr/bin/env bash
# Wrapper around kali-live's build.sh: stages our variant-kaliai config and
# the kaliai CLI/MCP-server source into the kali-live submodule checkout,
# then delegates to its build.sh. Must run on a Debian/Kali-family host with
# live-build installed (see kali-live/README.md) — this doesn't work from an
# Arch host.
#
# NOTE: this rsyncs into the submodule's shared kali-config/common/includes.chroot,
# so treat this checkout of kali-live as dedicated to building variant-kaliai.
# Building a different variant (e.g. --variant xfce) from this same checkout
# after running this script will carry kaliai's files along for the ride —
# use a separate clean checkout of kali-live for that.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO_DIR="$ROOT/distro"
SUBMODULE="$DISTRO_DIR/kali-live"
OVERLAY="$DISTRO_DIR/overlay"

if [[ ! -f "$SUBMODULE/build.sh" ]]; then
  echo "kaliai: $SUBMODULE is empty. Run: git submodule update --init" >&2
  exit 1
fi

echo "== Staging kaliai CLI + MCP server into the overlay (generated, not committed) =="
STAGE="$OVERLAY/includes.chroot/opt/kaliai"
rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -a "$ROOT/bin" "$ROOT/mcp-servers" "$ROOT/themes" "$STAGE/"

echo "== Linking variant-kaliai into the kali-live checkout =="
ln -sfn "$OVERLAY/kali-config/variant-kaliai" "$SUBMODULE/kali-config/variant-kaliai"

echo "== Merging overlay includes.chroot into kali-live's common includes.chroot =="
mkdir -p "$SUBMODULE/kali-config/common/includes.chroot"
rsync -a "$OVERLAY/includes.chroot/" "$SUBMODULE/kali-config/common/includes.chroot/"

echo "== Building (delegating to kali-live/build.sh --variant kaliai) =="
cd "$SUBMODULE"
exec ./build.sh --variant kaliai "$@"
