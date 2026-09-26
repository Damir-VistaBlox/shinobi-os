#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v dpkg-deb >/dev/null 2>&1 || { echo 'package-test: dpkg-deb is required' >&2; exit 1; }
package="$(mktemp --suffix=.deb)"
trap 'rm -f "$package"' EXIT

"$ROOT/packaging/build-deb.sh" "$package" >/dev/null
dpkg-deb --info "$package" | grep -Fq 'Package: shinobi-core'
dpkg-deb --info "$package" | grep -Fq 'Maintainer: Shinobi OS Maintainers'

contents="$(dpkg-deb --contents "$package")"
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
  grep -Fq "$path" <<<"$contents" || { echo "package-test: missing $path" >&2; exit 1; }
done

# The server resolves every manifest at import time and refuses to start if one
# is missing or malformed, so the packaged copies are checked by the same loader
# the server uses -- and against the source, so packaging cannot quietly ship a
# different policy than the repository holds.
stage="$(mktemp -d)"
trap 'rm -f "$package"; rm -rf "$stage"' EXIT
dpkg-deb -x "$package" "$stage"

for name in dns-lookup http-headers nmap-scan whatweb-scan; do
  cmp -s "$stage/usr/share/shinobi/tools/$name.toml" "$ROOT/tools/$name.toml" \
    || { echo "package-test: $name.toml differs from the source manifest" >&2; exit 1; }
done

PYTHONPATH="$ROOT/mcp-servers/shinobi-recon" python3 -c '
import sys
from shinobi_recon.registry import load_all
manifests = load_all(sys.argv[1])
assert len(manifests) == 4, f"expected 4 packaged manifests, got {len(manifests)}"
assert "nmap_scan" in manifests and manifests["nmap_scan"].requires_approval, "nmap lost its approval gate"
assert manifests["nmap_scan"].timeout_seconds == 900, "nmap lost its timeout"
' "$stage/usr/share/shinobi/tools" \
  || { echo "package-test: the packaged manifests do not load" >&2; exit 1; }
echo "package-test: packaged manifests match source and load cleanly"

echo 'package-test: PASS'
