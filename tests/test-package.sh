#!/usr/bin/env bash
# Validate the package that both the ISO hook and install.sh produce.
#
# Almost everything worth knowing about this package is a property of the staged
# tree, so that is what gets checked: the file list, the permissions on the
# executables, and above all that the packaged tool manifests are byte-identical
# to the source and still load through the same registry the server uses. A
# package that ships a stale copy of a manifest ships a different security
# policy than the repository says, and the server would enforce that copy
# without complaint.
#
# dpkg-deb is only needed for the two things a directory cannot answer: the
# control metadata, and the archive actually being a well-formed .deb. Where the
# tool is missing, those two checks are reported as skipped and everything else
# still runs, so a non-Debian host gets real coverage instead of a blank skip.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

skipped=0
stage=""
package=""
cleanup() {
  # The staged tree carries the shipped directory modes, and some of those are
  # read-only by design. rm cannot unlink inside a directory it cannot write,
  # so restore write permission first or the trap fails, leaves the temp tree
  # behind, and buries the assertion that actually failed.
  [[ -n "$stage" ]] && chmod -R u+rwX "$stage" 2>/dev/null
  [[ -n "$stage" ]] && rm -rf "$stage"
  [[ -n "$package" ]] && rm -f "$package"
  return 0
}
trap cleanup EXIT

if command -v dpkg-deb >/dev/null 2>&1; then
  package="$(mktemp --suffix=.deb)"
  "$ROOT/packaging/build-deb.sh" "$package" >/dev/null

  dpkg-deb --info "$package" | grep -Fq 'Package: shinobi-core' \
    || { echo 'package-test: package name is not shinobi-core' >&2; exit 1; }
  dpkg-deb --info "$package" | grep -Fq 'Maintainer: Shinobi OS Maintainers' \
    || { echo 'package-test: maintainer metadata is wrong' >&2; exit 1; }

  # dpkg-deb --contents prefixes each entry with its mode and owner, so strip
  # that and compare on the path, which is the part that matters here.
  contents="$(dpkg-deb --contents "$package" | awk '{print $NF}')"
  extracted="$(mktemp -d)"
  stage="$extracted"
  dpkg-deb -x "$package" "$stage"
else
  skipped=1
  stage="$(SHINOBI_DEB_STAGE_ONLY=1 "$ROOT/packaging/build-deb.sh")"
  # Same paths, derived from the tree rather than from the archive listing.
  contents="$(cd "$stage" && find . -mindepth 1 \( -type f -o -type l \) -printf './%P\n' | sort)"
  echo 'package-test: dpkg-deb unavailable, checking the staged tree only'
  echo 'package-test: SKIPPED control metadata and .deb well-formedness'
fi

for path in \
  ./usr/bin/shinobi \
  ./usr/bin/shinobi-version \
  ./usr/bin/shinobi-config \
  ./usr/lib/systemd/user/shinobi-desktop.target \
  ./usr/lib/systemd/user/shinobi-agentd.service \
  ./usr/lib/systemd/user/shinobi-contextd.service \
  ./usr/lib/systemd/user/shinobi-shell.service \
  ./usr/lib/shinobi/shinobi-agentd \
  ./usr/lib/shinobi/shinobi-agentctl \
  ./usr/lib/shinobi/shinobi-contextd \
  ./usr/lib/shinobi/shinobi-contextctl \
  ./usr/share/shinobi/version \
  ./usr/share/shinobi/policy/README \
  ./usr/share/shinobi/capabilities/README \
  ./usr/share/shinobi/tools/nmap-scan.toml \
  ./usr/share/shinobi/tools/whatweb-scan.toml \
  ./usr/share/shinobi/tools/dns-lookup.toml \
  ./usr/share/shinobi/tools/http-headers.toml \
  ./usr/share/shinobi/themes/kali-dark/theme.toml
do
  grep -Fxq "$path" <<<"$contents" || { echo "package-test: missing $path" >&2; exit 1; }
done
echo "package-test: all 19 expected paths are present"

# The server resolves every manifest at import time and refuses to start if one
# is missing or malformed, so the packaged copies are checked by the same loader
# the server uses -- and against the source, so packaging cannot quietly ship a
# different policy than the repository holds.
for name in dns-lookup http-headers nmap-scan whatweb-scan; do
  cmp -s "$stage/usr/share/shinobi/tools/$name.toml" "$ROOT/tools/$name.toml" \
    || { echo "package-test: $name.toml differs from the source manifest" >&2; exit 1; }
done
echo 'package-test: packaged manifests are byte-identical to the source'

# A manifest copied with the wrong mode, or a loader that silently tolerates a
# bad field, would both pass the checks above.
PYTHONPATH="$ROOT/mcp-servers/shinobi-recon" python3 -c '
import sys
from shinobi_recon.registry import load_all
manifests = load_all(sys.argv[1])
assert len(manifests) == 4, f"expected 4 packaged manifests, got {len(manifests)}"
assert "nmap_scan" in manifests and manifests["nmap_scan"].requires_approval, "nmap lost its approval gate"
assert manifests["nmap_scan"].timeout_seconds == 900, "nmap lost its timeout"
assert manifests["http_headers"].binary is None, "http_headers should stay in-process"
' "$stage/usr/share/shinobi/tools" \
  || { echo 'package-test: the packaged manifests do not load' >&2; exit 1; }
echo 'package-test: packaged manifests load cleanly with policy intact'

for exe in \
  usr/bin/shinobi \
  usr/bin/shinobi-version \
  usr/bin/shinobi-config \
  usr/lib/shinobi/shinobi-agentd \
  usr/lib/shinobi/shinobi-agentctl \
  usr/lib/shinobi/shinobi-contextd \
  usr/lib/shinobi/shinobi-contextctl
do
  [[ -x "$stage/$exe" ]] || { echo "package-test: $exe is not executable in the package" >&2; exit 1; }
done
echo 'package-test: shipped executables are executable'

# Bytecode caches are build residue. They show up as soon as anyone imports a
# module, so if they are not pruned they make the .deb depend on whether the
# builder ran the tests first.
stray="$(cd "$stage" && find . -name __pycache__ -o -name '*.pyc' -o -name '*.pyo' | head -5)"
[[ -z "$stray" ]] || { printf 'package-test: build residue shipped: %s\n' "$stray" >&2; exit 1; }
echo 'package-test: no bytecode residue in the package'

if (( skipped )); then
  echo 'package-test: PASS (staged tree only; .deb itself unverified on this host)'
else
  echo 'package-test: PASS'
fi
