#!/usr/bin/env bash
# Build the canonical Shinobi package from the package skeleton plus the
# command/theme sources. Used by both the ISO hook and install.sh.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$(mktemp -d)"

# SHINOBI_DEB_STAGE_ONLY=1 stops before dpkg-deb and prints the staged tree
# instead, leaving it in place for the caller to inspect and remove. Almost
# everything worth checking about the package is a property of that tree; only
# the .deb metadata and the ar archive need the tool. This exists so a
# non-Debian host can still verify the file list and the packaged manifests
# rather than skipping the whole package.
if [[ -n "${SHINOBI_DEB_STAGE_ONLY:-}" ]]; then
  trap - EXIT
else
  trap 'rm -rf "$stage"' EXIT
fi

cp -a "$root/packaging/shinobi-core/." "$stage/"
mkdir -p "$stage/usr/bin" "$stage/usr/share/shinobi/themes" "$stage/usr/share/shinobi/tools"
cp -a "$root/bin/shinobi" "$root"/bin/shinobi-* "$stage/usr/bin/"
cp -a "$root/bin/_shinobi-common.sh" "$stage/usr/bin/"
mkdir -p "$stage/usr/lib/shinobi"
cp -a "$root/libexec/shinobi/." "$stage/usr/lib/shinobi/"
cp -a "$root/themes/." "$stage/usr/share/shinobi/themes/"
cp -a "$root/tools/." "$stage/usr/share/shinobi/tools/"

# Bytecode caches are not source. They appear the moment anyone imports these
# modules, which the test suite does, so without this the .deb silently depends
# on whether the builder happened to run the tests first -- a clean checkout and
# a dirty one produce different packages. They are also the wrong arch when a
# builder's Python differs from the target's.
find "$stage" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$stage" -type f -name '*.pyc' -delete

chmod 0755 "$stage/usr/bin"/shinobi "$stage/usr/bin"/shinobi-* "$stage/usr/bin/_shinobi-common.sh" \
  "$stage/usr/lib/shinobi/shinobi-agentd" "$stage/usr/lib/shinobi/shinobi-agentctl" \
  "$stage/usr/lib/shinobi/shinobi-contextd" "$stage/usr/lib/shinobi/shinobi-contextctl" \
  "$stage/usr/lib/shinobi"/* 2>/dev/null || true

if [[ -n "${SHINOBI_DEB_STAGE_ONLY:-}" ]]; then
  echo "$stage"
  exit 0
fi

output="${1:-$root/shinobi-core.deb}"
dpkg-deb --build "$stage" "$output" >/dev/null
echo "$output"
