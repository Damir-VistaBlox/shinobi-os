#!/usr/bin/env bash
# Variant parity: the console-only variant must not end up with a different
# integration layer than the desktop one.
#
# variant-shinobi-min's tooling hook was an older copy of the desktop variant's,
# kept in sync by hand. It had drifted: it never installed shinobi-core, and
# instead symlinked /opt/shinobi/bin/* straight into /usr/local/bin. That is not
# a cosmetic difference. shinobi-core is what puts the tool manifests in
# /usr/share/shinobi/tools, and the MCP server resolves them there first,
# falling back to <parents[3]>/tools relative to its own file. Pip-installed
# into /opt/shinobi/venv, that fallback is /opt/shinobi/venv/lib/tools, which
# does not exist -- so on the min image the registry loads zero manifests and,
# since the registry fails closed, shinobi-recon refuses to start at all.
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

full_hook="$FULL/hooks/live/0020-shinobi-tooling.chroot"
min_hook="$MIN/hooks/live/0020-shinobi-tooling.chroot"

echo "== both variants exist and install the tooling layer =="
check "the desktop variant has a tooling hook" "$([[ -f "$full_hook" ]] && echo yes || echo no)" "yes"
check "the console variant has a tooling hook" "$([[ -f "$min_hook" ]] && echo yes || echo no)" "yes"

echo "== both variants install shinobi-core =="
for variant_hook in "$full_hook" "$min_hook"; do
  name="$(basename "$(dirname "$(dirname "$(dirname "$variant_hook")")")")"
  check "$name builds and installs the package" \
    "$(grep -q 'build-deb.sh' "$variant_hook" && grep -q 'dpkg -i' "$variant_hook" && echo yes || echo no)" "yes"
  check "$name does not bypass the package by symlinking the CLI" \
    "$(grep -q 'ln -sf "\$script"' "$variant_hook" && echo symlinks || echo no)" "no"
done

echo "== the two tooling hooks run the same commands =="
# The console variant's header claimed it was the desktop hook "minus the
# Quickshell-specific line", but that line no longer exists in the desktop hook,
# so there was no console-specific difference left to preserve -- only drift.
# Compare the executable lines rather than the bytes: the console copy carries a
# header explaining the duplication, and a comment cannot break an image, but a
# changed command can. This is what stops the hooks drifting apart a third time.
hook_body() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
if diff <(hook_body "$full_hook") <(hook_body "$min_hook") >/dev/null 2>&1; then
  check "the tooling hooks run identical commands" "same" "same"
else
  check "the tooling hooks run identical commands" \
    "$(diff <(hook_body "$full_hook") <(hook_body "$min_hook") | tr '\n' '|')" "same"
fi

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
for absent in 0005-single-desktop 0010-dotfiles 0030-fonts 0040-login-theme 0050-plymouth-theme; do
  check "$absent.chroot is absent from the console variant" \
    "$([[ -f "$MIN/hooks/live/$absent.chroot" ]] && echo present || echo absent)" "absent"
  check "$absent.chroot is present in the desktop variant" \
    "$([[ -f "$FULL/hooks/live/$absent.chroot" ]] && echo present || echo absent)" "present"
done

echo
if (( failures > 0 )); then
  printf 'variant-parity-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nvariant-parity-test: PASS\n' "$checks" "$checks"
