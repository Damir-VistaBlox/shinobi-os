#!/usr/bin/env bash
# Validate the package that both the ISO hook and install.sh produce.
#
# The staged tree is not enough to call a package verified: the point of the .deb
# is what a dpkg install actually lands on disk. So this builds the real archive
# and inspects that, which means it needs dpkg-deb and therefore Debian-family
# tooling. That is not a limitation to work around -- Kali is the target, and the
# hosted PR runners are Ubuntu, so the suite runs where it matters. Elsewhere it
# reports SKIPPED rather than pretending to have checked something.
#
# What it checks, and why each matters:
#   * control metadata, so the package is identifiable and attributable
#   * the file list, so a shipped component cannot quietly go missing
#   * exec bits, because a daemon that loses +x fails at start, not at build
#   * no bytecode residue, so the package does not depend on build order
#   * packaged manifests byte-identical to source and still loading with policy
#     intact, because a stale copy ships a different security policy than the
#     repository documents, and the server would enforce that copy silently
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo 'package-test: SKIPPED (dpkg-deb unavailable; needs a Debian-family host)'
  exit 0
fi

package="$(mktemp --suffix=.deb)"
stage="$(mktemp -d)"
# dpkg-deb -x reproduces the shipped directory modes, and rm cannot unlink
# inside a directory it cannot write, so restore write permission on the way out.
trap 'chmod -R u+rwX "$stage" "$package" 2>/dev/null; rm -rf "$stage" "$package"' EXIT

"$ROOT/packaging/build-deb.sh" "$package" >/dev/null

dpkg-deb --info "$package" | grep -Fq 'Package: shinobi-core' \
  || { echo 'package-test: package name is not shinobi-core' >&2; exit 1; }
dpkg-deb --info "$package" | grep -Fq 'Maintainer: Shinobi OS Maintainers' \
  || { echo 'package-test: maintainer metadata is wrong' >&2; exit 1; }

# --contents prefixes each entry with mode, owner and size, so compare on the
# path, which is the part the file-list check is about.
contents="$(dpkg-deb --contents "$package" | awk '{print $NF}')"
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
echo 'package-test: all 19 expected paths are present in the archive'

dpkg-deb -x "$package" "$stage"

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

# Bytecode caches are build residue: they appear as soon as anyone imports a
# module, so if they are not pruned the .deb depends on whether the builder ran
# the tests first, and ships bytecode built for the wrong Python and arch.
stray="$(cd "$stage" && find . -name __pycache__ -o -name '*.pyc' -o -name '*.pyo' | head -5)"
[[ -z "$stray" ]] || { printf 'package-test: build residue shipped:\n%s\n' "$stray" >&2; exit 1; }
echo 'package-test: no bytecode residue in the package'

# The server resolves every manifest at import time and refuses to start if one
# is missing or malformed, so the packaged copies are checked by the same loader
# the server uses -- and against the source, so packaging cannot quietly ship a
# different policy than the repository holds.
for name in dns-lookup http-headers nmap-scan whatweb-scan; do
  cmp -s "$stage/usr/share/shinobi/tools/$name.toml" "$ROOT/tools/$name.toml" \
    || { echo "package-test: $name.toml differs from the source manifest" >&2; exit 1; }
done
echo 'package-test: packaged manifests are byte-identical to the source'

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

echo 'package-test: PASS'
