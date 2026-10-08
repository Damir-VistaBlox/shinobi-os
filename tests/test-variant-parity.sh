#!/usr/bin/env bash
# Variant parity: the console-only variant must not end up with a different
# integration layer than the desktop one.
#
# variant-shinobi-min's tooling hook was an older copy of the desktop variant's,
# kept in sync by hand. It had drifted: it never installed shinobi-core, and
# instead symlinked /opt/shinobi/bin/* straight into /usr/local/bin. That is not
# a cosmetic difference. shinobi-core is what puts the tool manifests in
# /usr/share/shinobi/tools, and the MCP server resolves them there first,
# falling back to <parents[3]>/tools relative to its own file. Back when the
# server was pip-installed rather than packaged, that fallback was
# /opt/shinobi/venv/lib/tools, which does not exist -- so on the min image the
# registry loaded zero manifests and, since the registry fails closed,
# shinobi-recon refused to start at all. The server is packaged now and the
# fallback is never what saves a built image, but the drift is what this guards.
#
# These checks are static on purpose: the real proof needs an image build, but
# the chain that matters can be checked here -- both variants install the
# package, the package stages the manifests, and the two tooling hooks cannot
# drift apart again.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

FULL="$ROOT/distro/overlay/kali-config/variant-shinobi"
MIN="$ROOT/distro/overlay/kali-config/variant-shinobi-min"

failures=0
checks=0
check() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

# Found by what the hook does rather than by its number: the desktop hook was
# renamed to 0010-install-layer when the desktop layer became its own package,
# and this file kept pointing at 0020 -- a check on a file that no longer exists
# reads as a check on the one that does.
full_hook="$(grep -rl 'build-deb.sh' "$FULL/hooks/live/" | head -1)"
min_hook="$(grep -rl 'build-deb.sh' "$MIN/hooks/live/" | head -1)"

echo "== both variants exist and install the tooling layer =="
check "the desktop variant has a tooling hook" "$([[ -f "$full_hook" ]] && echo yes || echo no)" "yes"
check "the console variant has a tooling hook" "$([[ -f "$min_hook" ]] && echo yes || echo no)" "yes"

echo "== both variants install shinobi-core =="
for variant_hook in "$full_hook" "$min_hook"; do
  name="$(basename "$(dirname "$(dirname "$(dirname "$variant_hook")")")")"
  # Asserted on executable lines only. This previously grepped the whole file for
  # 'dpkg -i', and passed for the wrong reason: the desktop hook explained at
  # length why it uses apt instead, so the string was present in a comment while
  # no install line used it at all. The check was satisfied by prose about the
  # change rather than by the change.
  hook_cmds() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
  check "$name builds the package" \
    "$(hook_cmds "$variant_hook" | grep -q 'build-deb.sh' && echo yes || echo no)" "yes"
  # apt, not dpkg -i: the package depends on python3-mcp and python3-yaml, and
  # dpkg -i resolves nothing, so it would unpack the files and leave the package
  # unconfigured with the dependency absent.
  check "$name installs it with apt so Depends are resolved" \
    "$(hook_cmds "$variant_hook" | grep -qE 'apt-get install' && echo yes || echo no)" "yes"
  check "$name does not install it with a bare dpkg -i" \
    "$(hook_cmds "$variant_hook" | grep -qE '^[[:space:]]*(sudo )?dpkg -i' && echo dpkg || echo no)" "no"
  check "$name does not bypass the package by symlinking the CLI" \
    "$(grep -q 'ln -sf "\$script"' "$variant_hook" && echo symlinks || echo no)" "no"
done

echo "== each variant's hook does what that variant is =="
# These two used to be near-copies and the test asserted they were, which is what
# stopped them drifting. They are no longer the same shape -- the console image
# installs one package and writes provenance, the desktop installs two and applies
# the layer -- so comparing them byte for byte would now be asserting that the
# desktop has no desktop. What has to stay true is that both install the core
# package and both end up with provenance.
hook_body() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
check "the desktop hook installs the core package" \
  "$(hook_body "$full_hook" | grep -qE 'build-deb\.sh +"\$pkg"' && \
     grep -q 'for pkg in core desktop' "$full_hook" && echo yes || echo no)" "yes"
check "the console hook installs the core package" \
  "$(hook_body "$min_hook" | grep -qE 'build-deb\.sh +core' && echo yes || echo no)" "yes"
for name in desktop console; do
  [[ $name == desktop ]] && hook="$full_hook" || hook="$min_hook"
  check "$name writes provenance through the engine, not by hand" \
    "$(hook_body "$hook" | grep -q 'shinobi-setup' && echo yes || echo no)" "yes"
  check "$name does not write the provenance file itself" \
    "$(hook_body "$hook" | grep -qE '> */usr/share/shinobi/provenance' && echo by-hand || echo no)" "no"
done
check "only the desktop variant installs shinobi-desktop" \
  "$(grep -q 'for pkg in core desktop' "$full_hook" && echo yes || echo no)" "yes"
check "and the console variant does not" \
  "$(hook_body "$min_hook" | grep -q 'build-deb.sh desktop' && echo yes || echo no)" "no"

echo "== the package stages what the registry needs =="
check "build-deb.sh stages the tool manifests" \
  "$(grep -q 'cp -a "\$root/tools/\." "\$stage/usr/share/shinobi/tools/"' "$ROOT/packaging/build-deb.sh" && echo yes || echo no)" "yes"
check "the manifest directory the registry prefers is the one the package fills" \
  "$(grep -q 'Path("/usr/share/shinobi/tools")' "$ROOT/mcp-servers/shinobi-recon/shinobi_recon/registry.py" && echo yes || echo no)" "yes"
for manifest in dns-lookup http-headers nmap-scan whatweb-scan; do
  check "tools/$manifest.toml exists" "$([[ -f "$ROOT/tools/$manifest.toml" ]] && echo yes || echo no)" "yes"
done

echo "== the registry's source-tree fallback is not mistaken for an install path =="
# It walks out of the package to <repo>/tools. On a pip-installed server that is
# .../venv/lib/tools, so the fallback cannot be what saves a built image; only
# the packaged location can. Worth asserting so a future edit that reorders the
# search is caught here rather than on a booted image.
check "the packaged location is tried before the source tree" \
  "$(python3 - <<'PY'
import re, pathlib
src = pathlib.Path("mcp-servers/shinobi-recon/shinobi_recon/registry.py").read_text()
body = src[src.index("def tools_dir"):]
packaged = body.index("/usr/share/shinobi/tools")
fallback = body.index('parents[3] / "tools"')
print("yes" if packaged < fallback else "no")
PY
)" "yes"

echo "== the console variant is still console-only =="
# Guard the other direction: parity must not quietly pull the desktop in.
# 0010-dotfiles and 0030-fonts are gone: both became shinobi-setup's work, so the
# desktop layer is applied by the engine rather than by a hook per concern.
desktop_only_hooks=()
for hook_path in "$FULL"/hooks/live/*.chroot; do
  desktop_only_hooks+=("$(basename "$hook_path")")
done
for absent in "${desktop_only_hooks[@]}"; do
  check "$absent is absent from the console variant" \
    "$([[ -f "$MIN/hooks/live/$absent" ]] && echo present || echo absent)" "absent"
  check "$absent is present in the desktop variant" \
    "$([[ -f "$FULL/hooks/live/$absent" ]] && echo present || echo absent)" "present"
done

echo
if (( failures > 0 )); then
  printf 'variant-parity-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nvariant-parity-test: PASS\n' "$checks" "$checks"
