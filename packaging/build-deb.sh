#!/usr/bin/env bash
# Build the canonical Shinobi package from the package skeleton plus the
# command/theme sources. Used by both the ISO hook and install.sh.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$(mktemp -d)"
# The stage carries the shipped directory modes, some of which are read-only by
# design, and rm cannot unlink inside a directory it cannot write.
trap 'chmod -R u+rwX "$stage" 2>/dev/null; rm -rf "$stage"' EXIT

cp -a "$root/packaging/shinobi-core/." "$stage/"
mkdir -p "$stage/usr/bin" "$stage/usr/share/shinobi/themes" "$stage/usr/share/shinobi/tools" \
  "$stage/usr/share/shinobi/providers"
cp -a "$root/bin/shinobi" "$root"/bin/shinobi-* "$stage/usr/bin/"
cp -a "$root/bin/_shinobi-common.sh" "$stage/usr/bin/"
mkdir -p "$stage/usr/lib/shinobi"
cp -a "$root/libexec/shinobi/." "$stage/usr/lib/shinobi/"
cp -a "$root/themes/." "$stage/usr/share/shinobi/themes/"
cp -a "$root/tools/." "$stage/usr/share/shinobi/tools/"
cp -a "$root/providers/." "$stage/usr/share/shinobi/providers/"

# Bytecode caches are not source. They appear the moment anyone imports these
# modules, which the test suite does, so without this the .deb silently depends
# on whether the builder happened to run the tests first -- a clean checkout and
# a dirty one produce different packages. They are also built for the builder's
# Python and architecture, not the target's.
find "$stage" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$stage" -type f -name '*.pyc' -delete

chmod 0755 "$stage/usr/bin"/shinobi "$stage/usr/bin"/shinobi-* "$stage/usr/bin/_shinobi-common.sh" \
  "$stage/usr/lib/shinobi/shinobi-agentd" "$stage/usr/lib/shinobi/shinobi-agentctl" \
  "$stage/usr/lib/shinobi/shinobi-contextd" "$stage/usr/lib/shinobi/shinobi-contextctl" \
  "$stage/usr/lib/shinobi"/* 2>/dev/null || true

output="${1:-$root/shinobi-core.deb}"
dpkg-deb --build "$stage" "$output" >/dev/null
echo "$output"
