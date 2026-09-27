#!/usr/bin/env bash
# Build the canonical Shinobi package from the package skeleton plus the
# command/theme sources. Used by both the ISO hook and install.sh.
#
# `--stage <dir>` stops after laying out the tree and prints nothing else, so
# the package *contents* can be checked on a host with no dpkg-deb. Building the
# archive still needs Debian tooling; asserting what goes into it does not, and
# the contents are where the interesting mistakes are.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# --stage lays the tree out in a directory the caller owns and stops there.
# Everything except the final `dpkg-deb --build` is plain file copying, so the
# package contents can be asserted on a host that has no dpkg-deb at all.
stage_only=false
stage=""
if [[ "${1:-}" == "--stage" ]]; then
  stage="${2:?--stage needs a directory to lay the tree out in}"
  shift 2
  stage_only=true
fi

if [[ $stage_only == false ]]; then
  stage="$(mktemp -d)"
  # The stage carries the shipped directory modes, some of which are read-only by
  # design, and rm cannot unlink inside a directory it cannot write.
  trap 'chmod -R u+rwX "$stage" 2>/dev/null; rm -rf "$stage"' EXIT
fi

cp -a "$root/packaging/shinobi-core/." "$stage/"
mkdir -p "$stage/usr/bin" "$stage/usr/share/shinobi/themes" "$stage/usr/share/shinobi/tools" \
  "$stage/usr/share/shinobi/providers"
cp -a "$root/bin/shinobi" "$root"/bin/shinobi-* "$stage/usr/bin/"
cp -a "$root/bin/_shinobi-common.sh" "$stage/usr/bin/"
mkdir -p "$stage/usr/lib/shinobi"
cp -a "$root/libexec/shinobi/." "$stage/usr/lib/shinobi/"

# The recon server, as a private copy rather than into dist-packages.
#
# It is not a library other code should import: it is the component that
# enforces the scope gate and writes the audit log, and putting `shinobi_recon`
# in the system namespace would let a stray `pip install --user` shadow the copy
# those guarantees live in. Its dependency goes the other way -- `mcp` comes
# from apt (python3-mcp) and is imported normally -- so nothing here needs
# debhelper's dh_python3 to compute a dist-packages path, and nothing needs to
# own the byte-compilation of code it does not ship.
#
# The manifests are already above, at /usr/share/shinobi/tools, which the
# registry prefers over any copy inside the package.
mkdir -p "$stage/usr/lib/shinobi/mcp-servers"
cp -a "$root/mcp-servers/shinobi-recon/shinobi_recon" "$stage/usr/lib/shinobi/mcp-servers/"

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

if [[ $stage_only == true ]]; then
  exit 0
fi

output="${1:-$root/shinobi-core.deb}"
dpkg-deb --build "$stage" "$output" >/dev/null
echo "$output"
