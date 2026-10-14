#!/usr/bin/env bash
# Tests for the build's squashfs settings.
#
# distro/build.sh interpolates SHINOBI_SQUASHFS_COMPRESSION into
# kali-live/auto/config inside double quotes, and that file is a bash script
# that live-build executes. The value came from the environment with no
# validation, so anything containing a double quote was a shell injection into
# the build: a stray quote in a variable meant to hold "zstd" did not fail, it
# ran a command. It is set by whoever invokes the build rather than by a remote
# party, but the fix is an allowlist and there is no reason to keep the sharp
# edge.
#
# The validation lives in distro/lib/build-config.sh so it can be sourced and
# tested on its own; build.sh is a top-level script that builds an image, which
# is not something a test can invoke.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/distro/lib/build-config.sh"

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

[[ -f "$HELPER" ]] || { echo "missing $HELPER"; exit 1; }
# shellcheck source=/dev/null
. "$HELPER"

# Capture the status rather than letting the function's non-zero return trip
# `set -e` in the current shell when called outside a command substitution.
try() {
  local rc=0
  shinobi_resolve_squashfs "${1-}" "${2-}" 2>/dev/null || rc=$?
  echo "$rc"
}

echo "== live-build's compression types are accepted =="
for good in gzip xz zstd lz4 lzo none; do
  check "$good is accepted" "$(try "$good" 3)" "0"
done

echo "== a value that is not a compression type is rejected =="
for bad in \
  'ZSTD' 'zstd ' ' zstd' 'zstd; rm -rf /' 'zstd$(id)' 'zstd`id`' 'zstd|id' \
  'x" ; touch /tmp/opencode/build-config-pwned ; echo "' \
  'x"$(touch /tmp/opencode/build-config-pwned)"' \
  '"' "'" '\\' 'zstd
--second-option' '' 'zstd zstd'
do
  check "rejects $(printf '%q' "$bad")" "$(try "$bad" 3)" "1"
done

echo "== the injection never actually ran anything =="
rm -f /tmp/opencode/build-config-pwned
try 'x" ; touch /tmp/opencode/build-config-pwned ; echo "' 3 >/dev/null
try 'x"$(touch /tmp/opencode/build-config-pwned)"' 3 >/dev/null
check "no injected command executed" "$([[ -e /tmp/opencode/build-config-pwned ]] && echo EXECUTED || echo safe)" "safe"

echo "== levels must be a number, or none =="
for good in 0 1 3 9 19 22 none; do
  check "level $good is accepted" "$(try zstd "$good")" "0"
done
for bad in '' ' ' '3 ' ' 3' 'three' '3.5' '-1' '+3' '1; id' '$(id)' '`id`' '99999999999999999999' '3
4'; do
  check "rejects level $(printf '%q' "$bad")" "$(try zstd "$bad")" "1"
done

echo "== both arguments are required =="
check "an empty type is rejected" "$(try '' 3)" "1"
check "a missing type is rejected" "$(try)" "1"
check "a missing level is rejected" "$(try zstd)" "1"

echo "== a rejected setting explains itself =="
msg="$(shinobi_resolve_squashfs 'zstd; id' 3 2>&1 >/dev/null || true)"
check "the message names the variable" "$(grep -q 'SHINOBI_SQUASHFS_COMPRESSION' <<<"$msg" && echo yes || echo no)" "yes"
check "the message names the value" "$(grep -q 'zstd; id' <<<"$msg" && echo yes || echo no)" "yes"
msg="$(shinobi_resolve_squashfs zstd 'abc' 2>&1 >/dev/null || true)"
check "a bad level names its variable" "$(grep -q 'SHINOBI_SQUASHFS_LEVEL' <<<"$msg" && echo yes || echo no)" "yes"

echo "== build.sh actually uses the helper, and interpolates the validated value =="
check "build.sh sources the helper" \
  "$(grep -q 'lib/build-config.sh' "$ROOT/distro/build.sh" && echo yes || echo no)" "yes"
check "build.sh calls the validator before writing auto/config" \
  "$(grep -n 'shinobi_resolve_squashfs' "$ROOT/distro/build.sh" | head -1 | cut -d: -f1 | \
     awk -v w="$(grep -n 'AUTO_CONFIG.shinobi' "$ROOT/distro/build.sh" | head -1 | cut -d: -f1)" \
       'BEGIN{print ($1 < w) ? "yes" : "no"}')" "yes"
# The point is not that build.sh avoids the environment -- it must read it -- but
# that the value reaching auto/config is the validated one.
check "the awk interpolation uses the validated globals" \
  "$(grep -q 'v compression="\$SHINOBI_SQUASHFS_COMPRESSION"' "$ROOT/distro/build.sh" && \
     grep -q 'v level="\$SHINOBI_SQUASHFS_LEVEL"' "$ROOT/distro/build.sh" && echo yes || echo no)" "yes"
check "the env defaults are passed through the validator, not used directly" \
  "$(grep -q 'shinobi_resolve_squashfs \\' "$ROOT/distro/build.sh" && \
     grep -q '"\${SHINOBI_SQUASHFS_COMPRESSION:-zstd}"' "$ROOT/distro/build.sh" && echo yes || echo no)" "yes"

echo "== the staged chroot tree has everything the package build reads =="
# distro/build.sh stages a subset of the repo into the overlay's
# /opt/shinobi, and the image's tooling hook runs packaging/build-deb.sh from
# there rather than from the checkout. So a top-level path that build-deb.sh
# reads but build.sh does not stage is not a warning, it is a build that dies in
# the chroot: `providers` was missing, and the ISO build failed after fifteen
# minutes of live-build at `cp: cannot stat '/opt/shinobi/providers/.'`, on a
# branch whose source suite was green the whole time. Nothing local could see it,
# because the checkout has providers/ -- only the staged copy did not.
#
# Comparing the two lists is the whole check. It cannot tell you the staged tree
# is otherwise correct, but it catches the failure that costs a build.
staged_paths() {
  grep -oE '"\$ROOT/[a-z-]+"' "$ROOT/distro/build.sh" \
    | tr -d '"' | sed 's|\$ROOT/||' | sort -u
}
# The trailing slash matters: without it the pattern also matches the output
# path ($root/shinobi-$package.deb), and the check then reports a top-level path
# called "shinobi-" as unstaged, which is nonsense rather than a real finding.
needed_paths() {
  grep -oE '\$root/[a-z-]+/' "$ROOT/packaging/build-deb.sh" \
    | sed -e 's|\$root/||' -e 's|/$||' | sort -u
}
missing="$(comm -13 <(staged_paths) <(needed_paths))"
check "every path build-deb.sh reads is staged for the chroot" \
  "$([[ -z $missing ]] && echo yes || echo "no: $(tr '\n' ' ' <<<"$missing")")" "yes"
for path in bin libexec mcp-servers providers themes tools packaging; do
  # Matched as fixed text, not a pattern: the path is inside a quoted rsync
  # argument, and building the needle by concatenation keeps grep from reading
  # the dollars as anchors or the slashes as anything but slashes.
  needle='"$ROOT/'"$path"'"'
  check "$path is actually staged" \
    "$(grep -qF "$needle" "$ROOT/distro/build.sh" && echo yes || echo no)" "yes"
done

echo
if (( failures > 0 )); then
  printf 'build-config-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nbuild-config-test: PASS\n' "$checks" "$checks"
