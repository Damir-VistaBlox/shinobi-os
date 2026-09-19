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
  ./usr/share/shinobi/themes/kali-dark/theme.toml
do
  grep -Fq "$path" <<<"$contents" || { echo "package-test: missing $path" >&2; exit 1; }
done

echo 'package-test: PASS'
