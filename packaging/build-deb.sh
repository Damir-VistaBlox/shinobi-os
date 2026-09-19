#!/usr/bin/env bash
# Build the canonical Shinobi package from the package skeleton plus the
# command/theme sources. Used by both the ISO hook and install.sh.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -a "$root/packaging/shinobi-core/." "$stage/"
mkdir -p "$stage/usr/bin" "$stage/usr/share/shinobi/themes" "$stage/usr/share/shinobi/tools"
cp -a "$root/bin/shinobi" "$root"/bin/shinobi-* "$stage/usr/bin/"
cp -a "$root/bin/_shinobi-common.sh" "$stage/usr/bin/"
mkdir -p "$stage/usr/lib/shinobi"
cp -a "$root/libexec/shinobi/." "$stage/usr/lib/shinobi/"
cp -a "$root/themes/." "$stage/usr/share/shinobi/themes/"
cp -a "$root/tools/." "$stage/usr/share/shinobi/tools/"
chmod 0755 "$stage/usr/bin"/shinobi "$stage/usr/bin"/shinobi-* "$stage/usr/bin/_shinobi-common.sh" \
  "$stage/usr/lib/shinobi/shinobi-agentd" "$stage/usr/lib/shinobi/shinobi-agentctl" \
  "$stage/usr/lib/shinobi/shinobi-contextd" "$stage/usr/lib/shinobi/shinobi-contextctl" \
  "$stage/usr/lib/shinobi"/* 2>/dev/null || true
output="${1:-$root/shinobi-core.deb}"
dpkg-deb --build "$stage" "$output" >/dev/null
echo "$output"
