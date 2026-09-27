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
#   * every archived path owned by root/root, so a user account cannot own the
#     entry point or the systemd units the package installs
#   * packaged manifests byte-identical to source and still loading with policy
#     intact, because a stale copy ships a different security policy than the
#     repository documents, and the server would enforce that copy silently
#
# What goes *into* the package is checked on every host by
# tests/test-package-layout.sh, which needs none of this tooling. This file is
# about the archive dpkg actually receives.
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
expected=0
for path in \
  ./usr/bin/shinobi \
  ./usr/bin/shinobi-version \
  ./usr/bin/shinobi-config \
  ./usr/bin/shinobi-provider \
  ./usr/bin/shinobi-egress \
  ./usr/bin/shinobi-llm \
  ./usr/bin/shinobi-mcp \
  ./usr/lib/systemd/user/shinobi-desktop.target \
  ./usr/lib/systemd/user/shinobi-agentd.service \
  ./usr/lib/systemd/user/shinobi-contextd.service \
  ./usr/lib/systemd/user/shinobi-shell.service \
  ./usr/lib/shinobi/shinobi-agentd \
  ./usr/lib/shinobi/shinobi-agentctl \
  ./usr/lib/shinobi/shinobi-contextd \
  ./usr/lib/shinobi/shinobi-contextctl \
  ./usr/lib/shinobi/shinobi_control/providerctl.py \
  ./usr/lib/shinobi/shinobi_control/credentials.py \
  ./usr/lib/shinobi/shinobi_control/egress.py \
  ./usr/lib/shinobi/shinobi_control/llm/__init__.py \
  ./usr/lib/shinobi/shinobi_control/llm/transport.py \
  ./usr/lib/shinobi/shinobi_control/llm/wire.py \
  ./usr/lib/shinobi/shinobi_control/llm/mcp.py \
  ./usr/lib/shinobi/shinobi_control/llm/agent.py \
  ./usr/lib/shinobi/shinobi-llmctl \
  ./usr/lib/shinobi/shinobi_control/mcpctl.py \
  ./usr/lib/shinobi/shinobi-recon-check \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/__init__.py \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/argcheck.py \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/httpclient.py \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/process.py \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/registry.py \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/scope.py \
  ./usr/lib/shinobi/mcp-servers/shinobi_recon/server.py \
  ./usr/bin/shinobi-recon \
  ./usr/share/shinobi/version \
  ./usr/share/shinobi/policy/README \
  ./usr/share/shinobi/capabilities/README \
  ./usr/share/shinobi/tools/nmap-scan.toml \
  ./usr/share/shinobi/tools/whatweb-scan.toml \
  ./usr/share/shinobi/tools/dns-lookup.toml \
  ./usr/share/shinobi/tools/http-headers.toml \
  ./usr/share/shinobi/providers/openai.toml \
  ./usr/share/shinobi/providers/anthropic.toml \
  ./usr/share/shinobi/providers/ollama.toml \
  ./usr/share/shinobi/themes/kali-dark/theme.toml
do
  grep -Fxq "$path" <<<"$contents" || { echo "package-test: missing $path" >&2; exit 1; }
  expected=$((expected + 1))
done
# Counted rather than written down, so adding a shipped file cannot leave a
# stale number claiming a smaller package was fully checked.
echo "package-test: all $expected expected paths are present in the archive"

dpkg-deb -x "$package" "$stage"

for exe in \
  usr/bin/shinobi \
  usr/bin/shinobi-version \
  usr/bin/shinobi-config \
  usr/bin/shinobi-recon \
  usr/lib/shinobi/shinobi-agentd \
  usr/lib/shinobi/shinobi-agentctl \
  usr/lib/shinobi/shinobi-contextd \
  usr/lib/shinobi/shinobi-contextctl \
  usr/lib/shinobi/shinobi-recon-check
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

# Checked against the real archive, because this is a property of what dpkg
# receives rather than of the staging tree. Staging copies with `cp -a`, so
# without --root-owner-group the builder's uid is recorded and installed
# verbatim: install.sh builds from a user checkout, which would leave
# /usr/bin/shinobi-recon and the systemd user units owned by a normal account.
non_root="$(dpkg-deb --contents "$package" | awk '$2 != "root/root" {print $NF}' | head -5)"
if [[ -n $non_root ]]; then
  echo "package-test: these paths are not owned by root/root in the archive:" >&2
  printf '  %s\n' $non_root >&2
  exit 1
fi
echo 'package-test: every archived path is owned by root/root'

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

# Provider manifests get the same treatment, and it matters more here: the
# egress field is the one that decides whether engagement data may leave the
# machine, so a packaged copy that disagrees with the source is a policy change
# that no other test would notice.
for name in openai anthropic ollama; do
  cmp -s "$stage/usr/share/shinobi/providers/$name.toml" "$ROOT/providers/$name.toml" \
    || { echo "package-test: $name.toml differs from the source manifest" >&2; exit 1; }
done
echo 'package-test: packaged provider manifests are byte-identical to the source'

PYTHONPATH="$ROOT/libexec/shinobi" python3 -c '
import sys
from shinobi_control import providerctl
providers = providerctl.load_all([sys.argv[1]])
assert len(providers) == 3, f"expected 3 packaged providers, got {len(providers)}"
# The classification is the security property, so assert it directly rather than
# trusting that a file which parsed also said the right thing.
assert providers["openai"].egress == "cloud", "openai must be cloud"
assert providers["anthropic"].egress == "cloud", "anthropic must be cloud"
assert providers["ollama"].egress == "local", "ollama must be local"
assert providers["ollama"].reachable_on, "the local provider must pin its peers"
assert providers["openai"].requires_key is True, "openai must need a key"
assert providers["ollama"].requires_key is False, "the local provider must not need a key"
' "$stage/usr/share/shinobi/providers" \
  || { echo 'package-test: the packaged provider manifests do not load' >&2; exit 1; }
echo 'package-test: packaged providers load with their egress classification intact'

# A credential must never be part of the package. Keys are per-user state under
# XDG_STATE_HOME, so anything key-shaped under the shipped data directory is a
# leak rather than a default. The scan looks for stored key files specifically;
# credentials.py is the broker's source and belongs in the package.
stray_key="$(find "$stage/usr/share/shinobi/providers" -type f -name '*.key' -print -quit)"
[[ -z "$stray_key" ]] || { echo "package-test: a stored key is packaged: $stray_key" >&2; exit 1; }
echo 'package-test: no stored credential material in the package'

echo 'package-test: PASS'
