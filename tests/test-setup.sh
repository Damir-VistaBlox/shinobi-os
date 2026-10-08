#!/usr/bin/env bash
# The engine that applies the Shinobi layer, tested against real behaviour.
#
# shinobi-setup edits a home directory, renames an account, rewrites sudoers
# rules, unpacks a font into a system directory and writes the provenance file.
# Every one of those can go quietly wrong on a machine somebody is working on,
# so this exercises the engine in a real Kali container against a real chroot
# rather than asserting on its source text: a `grep`-based check passes on a
# script whose logic is inverted.
#
# It re-execs itself inside a Kali container when it is not already root, so the
# behaviour under test is the same on a workstation and in CI.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/libexec/shinobi/shinobi-setup"

# --- enter a root environment, or say why we cannot --------------------------
if [[ ${SHINOBI_SETUP_TEST_CHILD:-} != 1 ]]; then
  if [[ $(id -u) != 0 ]] || ! command -v busybox >/dev/null 2>&1; then
    if command -v docker >/dev/null 2>&1; then
      exec docker run --rm -v "$ROOT:/repo:ro" -w /repo kalilinux/kali-rolling:latest \
        bash -c 'apt-get update -qq >/dev/null 2>&1 &&
                 apt-get install -y -qq busybox-static passwd >/dev/null 2>&1 &&
                 SHINOBI_SETUP_TEST_CHILD=1 bash tests/test-setup.sh'
    fi
    echo "setup-test: SKIP (needs root or docker to build a chroot to test against)"
    exit 0
  fi
fi

failures=0
checks=0

# usermod and its libraries, copied in rather than stubbed.
#
# Renaming an account is the step whose behaviour matters most here and the one
# a hand-written stand-in would most likely get wrong -- a stub that "renames"
# without moving the home, or without touching shadow, would let a real bug pass.
# Busybox has no usermod, so the real binary and what it links against go in.
install_usermod() {
  local root="$1" bin
  bin=$(command -v usermod 2>/dev/null) || return 0
  mkdir -p "$root/usr/sbin" "$root/usr/lib/x86_64-linux-gnu" "$root/lib/x86_64-linux-gnu"
  cp -a "$bin" "$root/usr/sbin/usermod"
  # The interpreter is named ld-linux-*.so.2 and reached through /lib64, a
  # symlink to the multiarch directory. Without it the binary is present and
  # every exec of it fails with ENOENT, which reads as "usermod: not found" --
  # a missing dependency, reported as a missing command.
  {
    ls /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 2>/dev/null
    ldd "$bin" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*'
  } | sort -u | while read -r lib; do
    [ -f "$lib" ] || continue
    mkdir -p "$root$(dirname "$lib")"
    cp -aL "$lib" "$root$lib" 2>/dev/null
  done
  mkdir -p "$root/lib64"
  ln -sf ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$root/lib64/ld-linux-x86-64.so.2"
  # The files backend, which is what a system with no directory service uses,
  # plus the two files usermod reads and refuses to run without.
  printf 'passwd: files\ngroup: files\nshadow: files\n' >"$root/etc/nsswitch.conf"
  [ -f "$root/etc/shadow" ] || : >"$root/etc/shadow"
  chmod 640 "$root/etc/shadow"
  [ -f "$root/etc/login.defs" ] || printf 'USERGROUPS_ENAB yes\n' >"$root/etc/login.defs"
}


check() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

section() { printf '\n== %s ==\n' "$1"; }

bash -n "$ENGINE" || {
  echo "setup-test: the engine is not valid shell" >&2
  exit 1
}
check "the engine is valid shell" "ok" "ok"

section "arguments"
check "no arguments prints usage rather than acting" \
  "$("$ENGINE" 2>&1 | head -1 | grep -c '^shinobi-setup -- apply' || true)" "1"
check "an unknown subcommand is refused" \
  "$("$ENGINE" frobnicate >/dev/null 2>&1; echo $?)" "64"
check "an unknown option is refused rather than ignored" \
  "$("$ENGINE" apply --not-a-flag >/dev/null 2>&1; echo $?)" "64"

# --- build a throwaway system to apply the layer to ---------------------------
# A chroot, not a mock: the engine calls getent, usermod, chown and rsync, and
# the behaviour worth testing is what those do to a real home directory.
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

mkdir -p "$R"/{bin,etc/sudoers.d,etc/skel,usr/local/bin,usr/share,tmp,home,var/lib,dev,proc}
chmod 1777 "$R/tmp"
cp "$(command -v busybox)" "$R/bin/busybox"
chroot "$R" /bin/busybox --install -s /bin
# The engine writes diagnostics to stderr and usermod and the shell both need
# /dev/null; without it every write fails and every assertion afterwards is
# measuring the missing device rather than the engine.
# A plain file, not a device node: opening a node created inside the chroot fails
# with EACCES, and every `getent ... >/dev/null` in the engine would fail with it,
# which looks like the engine refusing to act rather than a broken /dev/null.
: >"$R/dev/null"
cp "$ENGINE" "$R/engine"
chmod 0755 "$R/engine"
install_usermod "$R"
ln -sf /engine "$R/usr/local/bin/shinobi-setup"

# busybox has no getent, and the engine uses it to resolve an account -- which is
# the correct call on a real system (it asks NSS, not /etc/passwd directly). This
# stands in for the files backend a system without LDAP or SSSD actually uses, so
# the engine sees the same answers it would see on a live box.
cat >"$R/usr/local/bin/getent" <<'SHIM'
#!/bin/sh
# getent passwd [name] -- the only query the engine makes.
[ "$1" = passwd ] || exit 2
if [ -n "${2:-}" ]; then
  grep "^$2:" /etc/passwd
else
  cat /etc/passwd
fi
SHIM
chmod 0755 "$R/usr/local/bin/getent"


# rsync's --chown is deliberately not provided. The engine follows its rsync
# with an explicit chown -R of the whole home, and that line is what this file
# asserts on -- so a stub that ignores the flag makes the assertion mean
# something. A stub that implemented it would make the chown assertion vacuous.
cat >"$R/usr/local/bin/rsync" <<'STUB'
#!/bin/sh
# Deliberately minimal: make the destination exist, then copy. Flags are
# accepted and ignored, including --chown, so the engine's own chown is what
# gets tested.
args=""
copy_flag="-a"
while [ $# -gt 0 ]; do
  case "$1" in
    --ignore-existing) copy_flag="-an" ;;
    -*) ;;
    *) args="$args $1" ;;
  esac
  shift
done
# shellcheck disable=SC2086
set -- $args
src="$1"
if [ $# -ge 2 ]; then
  dest="$2"
else
  dest="${src%/}/"
fi
mkdir -p "$dest"
# --ignore-existing is implemented here rather than passed to cp, because busybox
# cp has no -n and would either error or ignore the flag -- and a stub that
# overwrote anyway would make the engine's non-destructive default untestable.
for f in "$src"/.[!.]* "$src"/*; do
  [ -e "$f" ] || continue
  base="${f##*/}"
  if [ "$copy_flag" = "-an" ] && [ -e "$dest/$base" ]; then
    continue
  fi
  # A directory is merged, not nested: `cp -a dir dest/dir` copies *into* an
  # existing dest/dir and produces dest/dir/dir on the second run. rsync merges,
  # so the stub has to, or "running it twice changes nothing" measures the stub.
  if [ -d "$f" ]; then
    mkdir -p "$dest/$base"
    cp -a "$f"/. "$dest/$base"/
  else
    cp -a "$f" "$dest/$base"
  fi
done
STUB
chmod 0755 "$R/usr/local/bin/rsync"

# A real desktop layer to apply: staged from the package, so the test uses the
# same bytes the ISO hook and install.sh would install.
stage=$(mktemp -d)
"$ROOT/packaging/build-deb.sh" desktop --stage "$stage"
mkdir -p "$R/usr/share/shinobi"
cp -a "$stage/usr/share/shinobi-dotfiles" "$R/usr/share/"
rm -rf "$stage"
printf '0.1.0-test\n' >"$R/usr/share/shinobi/version"
printf 'ID=kali\nVERSION_ID="2026.7"\n' >"$R/etc/os-release"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$R/etc/passwd"
printf 'root:x:0:\n' >"$R/etc/group"

add_user() {
  local name="$1" uid="$2"
  printf '%s:x:%s:%s::/home/%s:/bin/sh\n' "$name" "$uid" "$uid" "$name" >>"$R/etc/passwd"
  printf '%s:x:%s:\n' "$name" "$uid" >>"$R/etc/group"
  mkdir -p "$R/home/$name"
}

section "a system with no account of its own"
# A minimal image, or a chroot, has only root. Applying dotfiles to root's home
# and reporting success would be a layer applied to the wrong account, which is
# not applied at all.
out=$(chroot "$R" /engine apply --skip-fonts 2>&1)
check "it refuses" "$?" "1"
check "and says what it found" \
  "$(grep -c 'no single login account' <<<"$out" || true)" "1"
check "and tells the operator how to name one" \
  "$(grep -c -- '--account' <<<"$out" || true)" "1"
check "and does not touch root's home" \
  "$([[ -d $R/root/.config/hypr ]] && echo touched || echo untouched)" "untouched"

add_user shinobi 1000

section "applying the layer"
out=$(chroot "$R" /engine apply --skip-fonts 2>&1)
check "it succeeds" "$?" "0"
check "it fills /etc/skel" \
  "$([[ -f $R/etc/skel/.config/hypr/hyprland.conf ]] && echo yes || echo no)" "yes"
check "it fills the account's home" \
  "$([[ -f $R/home/shinobi/.config/quickshell/shell.qml ]] && echo yes || echo no)" "yes"
check "it fills root's home too" \
  "$([[ -f $R/root/.config/hypr/hyprland.conf ]] && echo yes || echo no)" "yes"

section "provenance"
check "it is written" "$([[ -s $R/usr/share/shinobi/provenance ]] && echo yes || echo no)" "yes"
check "it names the base" "$(grep -c '^base=kali$' "$R/usr/share/shinobi/provenance" || true)" "1"
check "it states the relationship" \
  "$(grep -c '^relationship=overlay$' "$R/usr/share/shinobi/provenance" || true)" "1"
check "it carries the layer version" \
  "$(grep -c '^layer_version=0.1.0-test$' "$R/usr/share/shinobi/provenance" || true)" "1"
check "and the base's own id" \
  "$(grep -c '^base_id=2026.7$' "$R/usr/share/shinobi/provenance" || true)" "1"

section "ownership"
# The bug this fixes: rsync -a preserves the source tree's ownership, the
# staged tree is root-owned, and the first version chowned only .config -- so
# whether a home came out right depended on which subdirectory was listed. SDDM
# reports the result as "the home directory does not belong to the user you are
# currently creating".
check "the home belongs to the account" \
  "$(chroot "$R" stat -c %U /home/shinobi)" "shinobi"
check "a dotfile in it too" \
  "$(chroot "$R" stat -c %U /home/shinobi/.config/hypr/hyprland.conf)" "shinobi"
check "and /etc/skel does as well" \
  "$(chroot "$R" stat -c %U /etc/skel/.config/wofi/config)" "shinobi"

section "running it twice changes nothing"
before=$(find "$R/home/shinobi" "$R/etc/skel" -type f | sort | md5sum)
chroot "$R" /engine apply --skip-fonts >/dev/null 2>&1
check "the second run succeeds" "$?" "0"
after=$(find "$R/home/shinobi" "$R/etc/skel" -type f | sort | md5sum)
check "and the tree is identical" \
  "$([[ $before == "$after" ]] && echo same || echo changed)" "same"

section "an operator's own configuration survives a re-apply"
# A login that resets the operator's colours because a package was re-applied is
# not a repair; it is data loss with a progress message.
printf 'OPERATOR EDITS\n' >"$R/home/shinobi/.config/wofi/style.css"
chroot "$R" /engine apply --skip-fonts >/dev/null 2>&1
check "their edit is still there" \
  "$(cat "$R/home/shinobi/.config/wofi/style.css" || true)" "OPERATOR EDITS"
chroot "$R" /engine apply --force --skip-fonts >/dev/null 2>&1
check "--force restores the shipped file" \
  "$(grep -c 'OPERATOR EDITS' "$R/home/shinobi/.config/wofi/style.css" || true)" "0"

section "renaming an account is never implicit"
# A stock Kali box: the base account exists, Shinobi's does not. This is the only
# situation the rename exists for, and the one where getting it wrong leaves a
# system whose operator cannot sudo.
K=$(mktemp -d)
mkdir -p "$K"/{bin,etc/sudoers.d,etc/skel,usr/local/bin,usr/share,tmp,home,var/lib,dev}
chmod 1777 "$K/tmp"
cp "$(command -v busybox)" "$K/bin/busybox"
chroot "$K" /bin/busybox --install -s /bin
: >"$K/dev/null"
cp "$ENGINE" "$K/engine"
chmod 0755 "$K/engine"
install_usermod "$K"
cp -a "$R/usr/local/bin/rsync" "$R/usr/local/bin/getent" "$K/usr/local/bin/"
mkdir -p "$K/usr/share/shinobi"
cp -a "$R/usr/share/shinobi-dotfiles" "$K/usr/share/"
printf '0.1.0-test\n' >"$K/usr/share/shinobi/version"
printf 'ID=kali\nVERSION_ID="2026.7"\n' >"$K/etc/os-release"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$K/etc/passwd"
printf 'root:x:0:\n' >"$K/etc/group"
printf 'kali:x:1000:1000::/home/kali:/bin/sh\n' >>"$K/etc/passwd"
printf 'kali:x:1000:\n' >>"$K/etc/group"
mkdir -p "$K/home/kali"
# A rule from the base image naming the account, and one that only looks like it
# does -- rewriting the second into shinobi-tools would break a package's tool.
printf 'kali ALL=(ALL) NOPASSWD: ALL\n' >"$K/etc/sudoers.d/kali"
printf 'root ALL=(ALL) NOPASSWD: ALL\n' >"$K/etc/sudoers.d/kali-tools"

chroot "$K" /engine apply --skip-fonts >/dev/null 2>&1
check "a bare apply applies the layer but does not rename the account" \
  "$(chroot "$K" getent passwd kali >/dev/null && echo still-there || echo gone)" "still-there"
check "and it reached that account's home" \
  "$([[ -f $K/home/kali/.config/hypr/hyprland.conf ]] && echo yes || echo no)" "yes"

chroot "$K" /engine apply --rename-from kali --skip-fonts
check "--rename-from renames it" \
  "$(chroot "$K" getent passwd shinobi >/dev/null && echo yes || echo no)" "yes"
check "the old name is gone" \
  "$(chroot "$K" getent passwd kali >/dev/null && echo still-there || echo gone)" "gone"
check "the home moved with the account" \
  "$(chroot "$K" getent passwd shinobi | cut -d: -f6)" "/home/shinobi"
# usermod rewrites /etc/passwd and /etc/shadow; it does not touch sudoers.d. A
# rename without this leaves a system where sudo silently does nothing, which
# reads as a broken install rather than a missed step.
check "and the sudoers rule naming it is rewritten" \
  "$(cat "$K/etc/sudoers.d/kali" 2>/dev/null || true)" "shinobi ALL=(ALL) NOPASSWD: ALL"
check "while a rule that merely contains the name is left alone" \
  "$(cat "$K/etc/sudoers.d/kali-tools" 2>/dev/null || true)" "root ALL=(ALL) NOPASSWD: ALL"

echo "--- second rename apply ---"
chroot "$K" /engine apply --rename-from kali --skip-fonts
check "running it again with the old name succeeds" "$?" "0"
check "and does not rename shinobi a second time" \
  "$(chroot "$K" getent passwd shinobi | cut -d: -f3)" "1000"
rm -rf "$K"

section "status"
status=$(chroot "$R" /engine status --json 2>&1)
check "it reports the dotfiles present" "$(grep -c '"dotfiles":true' <<<"$status" || true)" "1"
check "it reports provenance present" "$(grep -c '"provenance":true' <<<"$status" || true)" "1"
check "it names the account" "$(grep -c '"account":"shinobi"' <<<"$status" || true)" "1"

section "a system with no desktop package installed"
# The engine has to say which package is missing. "Nothing happened" is the
# answer an operator cannot act on, and on a box where shinobi-menu exists this
# is the difference between a missing layer and a broken one.
E=$(mktemp -d)
mkdir -p "$E"/{bin,etc,usr/local/bin,usr/share,tmp,home,var/lib,dev}
chmod 1777 "$E/tmp"
cp "$(command -v busybox)" "$E/bin/busybox"
chroot "$E" /bin/busybox --install -s /bin
: >"$E/dev/null"
cp "$ENGINE" "$E/engine"
chmod 0755 "$E/engine"
ln -sf /engine "$E/usr/local/bin/shinobi-setup"
cp "$R/usr/local/bin/getent" "$E/usr/local/bin/getent"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$E/etc/passwd"
printf 'root:x:0:\n' >"$E/etc/group"
add_user() {
  printf 'shinobi:x:1000:1000::/home/shinobi:/bin/sh\n' >>"$E/etc/passwd"
  printf 'shinobi:x:1000:\n' >>"$E/etc/group"
  mkdir -p "$E/home/shinobi"
}
add_user
out=$(chroot "$E" /engine apply --skip-fonts 2>&1)
check "it fails" "$?" "1"
check "and names the package to install" \
  "$(grep -c 'Install shinobi-desktop' <<<"$out" || true)" "1"
rm -rf "$E"

section "the font is installed by a separate, verifiable step"
# The font step is its own shipped script rather than a function here, because it
# is the only part of applying the layer that touches the network and unpacks
# bytes into a system directory. tests/test-fonts-hook.sh exercises that script's
# real behaviour with a stubbed curl; this only asserts the wiring, because the
# checksum, the verify-before-unpack ordering and the cleanup all live there now.
FONT="$ROOT/libexec/shinobi/install-nerd-font"
check "the font installer is shipped" "$([[ -x $FONT ]] && echo yes || echo no)" "yes"
check "the engine calls it" \
  "$(grep -q 'install-nerd-font' "$ENGINE" && echo yes || echo no)" "yes"
check "and does not carry a second copy of the download" \
  "$(grep -q 'curl -fsSL' "$ENGINE" && echo yes || echo no)" "no"
check "the installer pins a checksum" \
  "$(grep -q 'NERD_FONT_SHA256="fab782a6' "$FONT" && echo yes || echo no)" "yes"
verify_line=$(grep -n 'sha256sum "$archive"' "$FONT" | cut -d: -f1)
unzip_line=$(grep -n 'unzip -o -q' "$FONT" | cut -d: -f1)
check "and verifies it before unpacking" \
  "$([[ -n $verify_line && -n $unzip_line && $verify_line -lt $unzip_line ]] && echo yes || echo no)" "yes"

printf '\n'
if ((failures > 0)); then
  printf 'setup-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nsetup-test: PASS\n' "$checks" "$checks"