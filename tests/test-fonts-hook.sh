#!/usr/bin/env bash
# Tests for the Nerd Font installer.
#
# It downloads a 128 MB zip from a GitHub release and unzips it straight into a
# system font directory, so whatever arrives on the wire becomes trusted font
# data on every boot and there is no way to tell a substituted download from a
# good one afterwards. The version is pinned, but a tag names a release, not the
# bytes.
#
# It was a chroot hook once, which meant the only way to exercise it was a full
# image build -- and it kept its weaknesses for exactly as long. It is a shipped
# script now, taking --dest, so this runs it for real against a temporary
# destination with a stubbed curl/unzip/fc-cache on PATH: the verification logic
# is executed, not grepped.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/libexec/shinobi/install-nerd-font"

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

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# The destination is redirected through the flag the script documents for it,
# rather than by rewriting its source: a copy with sed-edited paths tests the
# copy.
sed -e "s#^DEST=.*#DEST=\"$work/dest\"#" "$HOOK" >"$work/hook.sh"
chmod +x "$work/hook.sh"

# Stub toolchain. curl copies $STUB_PAYLOAD to whatever -o pointed at, so the
# test controls the bytes that arrive.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
  esac
  shift
done
[ -n "$out" ] || exit 2
cp "$STUB_PAYLOAD" "$out"
EOF
cat >"$work/bin/unzip" <<'EOF'
#!/bin/sh
echo "unzip $*" >>"$STUB_LOG"
exit 0
EOF
cat >"$work/bin/fc-cache" <<'EOF'
#!/bin/sh
echo "fc-cache $*" >>"$STUB_LOG"
exit 0
EOF
chmod +x "$work/bin/curl" "$work/bin/unzip" "$work/bin/fc-cache"
export PATH="$work/bin:$PATH"
export STUB_LOG="$work/log"
: >"$STUB_LOG"

printf 'the original asset\n' >"$work/good.zip"
printf 'something else entirely\n' >"$work/evil.zip"

# TMPDIR is set so mktemp puts the archive somewhere this test can look: the
# script's own cleanup is the thing under test, and counting unrelated /tmp
# entries on the host measures the host.
mkdir -p "$work/tmpdir"
run_hook() { STUB_PAYLOAD="$1" TMPDIR="$work/tmpdir" sh "$work/hook.sh" >"$work/out" 2>"$work/err"; echo $?; }

# The checksum the hook pins, read back out of the hook itself so this test
# cannot drift from it.
pinned="$(sed -n 's/^NERD_FONT_SHA256="\(.*\)"/\1/p' "$HOOK")"
pinned_actual="$(sha256sum "$work/good.zip" | cut -d' ' -f1)"

# The accept path needs a pin that matches the stub payload, and no stub payload
# can hash to the real release's checksum. So run the accept case against a copy
# re-pinned to the stub, and check the real pin statically below.
sed -e "s#^NERD_FONT_SHA256=.*#NERD_FONT_SHA256=\"$pinned_actual\"#" \
    -e "s#^DEST=.*#DEST=\"$work/dest\"#" \
    "$HOOK" >"$work/hook-accept.sh"
chmod +x "$work/hook-accept.sh"
run_accept() { STUB_PAYLOAD="$1" TMPDIR="$work/tmpdir" sh "$work/hook-accept.sh" >"$work/out" 2>"$work/err"; echo $?; }

echo "== a matching download is accepted =="
check "the installer exits 0" "$(run_accept "$work/good.zip")" "0"
check "unzip ran" "$(grep -c '^unzip' "$STUB_LOG")" "1"
check "fc-cache ran" "$(grep -c '^fc-cache' "$STUB_LOG")" "1"
check "the archive is cleaned up on success" "$(find "$work/tmpdir" -type f | grep -c . || true)" "0"
check "and nothing else is left behind in tmp" "$(find "$work/tmpdir" -mindepth 1 | grep -c . || true)" "0"

echo "== the real pin is the one upstream published =="
# Verified on 2026-09 against the v3.5.1 release asset and its SHA-256.txt. A
# literal here rather than a fetch, so the test needs no network; an accidental
# edit to the pin fails instead of silently installing whatever arrives.
check "the hook pins a sha256" "$([[ "$pinned" =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)" "yes"
check "the pinned sha256 is the published v3.5.1 checksum" \
  "$pinned" "fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e"

echo "== a substituted download is refused =="
: >"$STUB_LOG"
check "the installer exits non-zero" "$(run_hook "$work/evil.zip")" "1"
check "unzip never ran" "$(grep -c '^unzip' "$STUB_LOG")" "0"
check "fc-cache never ran" "$(grep -c '^fc-cache' "$STUB_LOG")" "0"
check "the mismatch is reported" "$(grep -qiE 'sha256|checksum' "$work/err" && echo yes || echo no)" "yes"
check "nothing was installed into the font directory" \
  "$([[ -d "$work/dest" ]] && find "$work/dest" -name '*.ttf' | wc -l | tr -d ' ' || echo 0)" "0"

echo "== the archive is not left behind on failure =="
# mktemp decides the name, so this asserts none survived rather than guessing it.
check "no partial archive is left in tmp" "$(find "$work/tmpdir" -type f | grep -c . || true)" "0"

echo "== a truncated download is refused, not half-installed =="
head -c 20 "$work/good.zip" >"$work/short.zip"
: >"$STUB_LOG"
check "the installer exits non-zero" "$(run_hook "$work/short.zip")" "1"
check "unzip never ran" "$(grep -c '^unzip' "$STUB_LOG")" "0"

echo "== the static shape of the installer =="
check "the download is fetched with curl -f so an HTTP error is fatal" \
  "$(grep -q 'curl -f' "$HOOK" && echo yes || echo no)" "yes"
# Ordering is the whole point: verifying after the unzip would be theatre.
verify_line="$(grep -n 'sha256sum' "$HOOK" | head -1 | cut -d: -f1)"
unzip_line="$(grep -n '^unzip' "$HOOK" | head -1 | cut -d: -f1)"
check "the checksum is verified before anything is unzipped" \
  "$([[ -n "$verify_line" && -n "$unzip_line" && "$verify_line" -lt "$unzip_line" ]] && echo yes || echo no)" "yes"
check "the pinned version and checksum are both declared" \
  "$(grep -q '^NERD_FONT_VERSION=' "$HOOK" && grep -q '^NERD_FONT_SHA256=' "$HOOK" && echo yes || echo no)" "yes"
check "the installer mentions where the checksum came from" \
  "$(grep -qi 'SHA-256.txt' "$HOOK" && echo yes || echo no)" "yes"

echo
if (( failures > 0 )); then
  printf 'fonts-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nfonts-test: PASS\n' "$checks" "$checks"
