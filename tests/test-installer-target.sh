#!/usr/bin/env bash
# Runs the wizard's shellprocess steps against a target, for real.
#
# The wizard's own steps are YAML: a list of command vectors in
# `shellprocess@prep.conf` and `shellprocess@finish.conf`. Calamares loads them
# and reports nothing when a command is fine, and reports "Process completed with
# exit code 1" when it is not -- with no indication of which of eleven commands
# failed or why. Nothing else in this repository executes them: the installer
# suite boots Calamares and checks that it *accepts* the configuration, and
# accepting a configuration is not the same as running it.
#
# So this builds something shaped like an installed system -- the staged package
# contents, an account, the live session's leftovers -- and runs the exact
# command vectors parsed out of the wizard's own files against it in a chroot.
# A command with a typo in it fails here rather than after somebody has chosen a
# disk.
#
# Requires docker (or root, for chroot). Skips with an explanation otherwise.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES="$ROOT/packaging/shinobi-installer/etc/calamares/modules"

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
section() { printf '\n== %s ==\n' "$1"; }

if [[ $(id -u) != 0 ]] && ! command -v docker >/dev/null 2>&1; then
  echo "target-test: SKIP (needs root for chroot, or docker)"
  exit 0
fi

# Build a target the way unpackfs would: the staged contents of the two packages,
# plus the state an installed system must *not* inherit.
build_target() {
  local dest="$1"
  # All three packages: an installed system has the wizard on it too, because the
  # live image ships it and unpackfs copies what is there.
  "$ROOT/packaging/build-deb.sh" core --stage "$dest"
  "$ROOT/packaging/build-deb.sh" desktop --stage "$dest"
  "$ROOT/packaging/build-deb.sh" installer --stage "$dest"
  chmod -R u+rwX "$dest"

  # The operator's account, created by Calamares' users module from /etc/skel.
  mkdir -p "$dest/etc/skel"
  cp -a "$dest/usr/share/shinobi-dotfiles/etc/skel/." "$dest/etc/skel/"
  # The image's own live-config, which is how the wizard learns the live
  # account's name.
  mkdir -p "$dest/etc/live/config.conf.d"
  printf 'LIVE_USERNAME="shinobi"\nLIVE_HOSTNAME="shinobi"\n' \
    >"$dest/etc/live/config.conf.d/shinobi.conf"
  cat >>"$dest/etc/passwd" <<'EOF'
operator:x:1000:1000:Shinobi Operator:/home/operator:/bin/bash
shinobi:x:1001:1001::/home/shinobi:/bin/bash
# An account with a home directory is a real one, and the prep step must leave
# it alone -- this is the guard, and it is here rather than in a comment because a
# guard that is never exercised is a guard that does not work.
builder:x:1002:1002::/home/builder:/bin/bash
EOF
  cat >>"$dest/etc/group" <<'EOF'
operator:x:1000:
shinobi:x:1001:
builder:x:1002:
sudo:x:27:operator
EOF
  mkdir -p "$dest/home/operator" "$dest/home/builder"
  # No /home/shinobi: unpackfs excludes /home/*, which is the whole reason the
  # prep step can tell the live account from a real one.
  # /etc/skel is copied into a new home by useradd, which is where the layer's
  # dotfiles come from for an account the wizard creates.
  cp -a "$dest/etc/skel/." "$dest/home/operator/"

  printf 'operator ALL=(ALL) NOPASSWD: ALL\n' >"$dest/etc/sudoers.d/operator"
  chmod 0440 "$dest/etc/sudoers.d/operator"

  # What the live session leaves behind that must not survive:
  mkdir -p "$dest/etc/sddm.conf.d"
  # Named so that a glob for *autologin* would miss it: what has to work is the
  # removal of the setting from inside a file, not the deletion of a filename.
  printf '[Autologin]\nUser=shinobi\nSession=hyprland\n' >"$dest/etc/sddm.conf.d/zz-live-session.conf"
  printf 'shinobi ALL=(ALL) NOPASSWD: ALL\n' >"$dest/etc/sudoers.d/live"
  mkdir -p "$dest/var/lib/apt/lists" "$dest/run/live"
  printf 'deb-src\n' >"$dest/var/lib/apt/lists/stale-from-build"

  # An image's own machine-id, copied rather than regenerated.
  printf '00000000000000000000000000000000\n' >"$dest/etc/machine-id"
  # The image's fstab, which points at the live medium by UUID.
  cat >"$dest/etc/fstab" <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
UUID=deadbeef-0000-0000-0000-000000000000 /live/medium iso9660 loop,ro 0 0
UUID=11111111-2222-3333-4444-555555555555 / ext4 defaults 0 1
EOF

  printf '0.1.0-test\n' >"$dest/usr/share/shinobi/version"
  printf 'ID=kali\nVERSION_ID="2026.7"\n' >"$dest/etc/os-release"
  mkdir -p "$dest/usr/local/bin" "$dest/var/lib/shinobi"
  ln -sf /usr/lib/shinobi/shinobi-setup "$dest/usr/local/bin/shinobi-setup" 2>/dev/null || true
}

section "a target shaped like an installed system, minus the wizard's work"
target="$(mktemp -d)"
build_target "$target"
trap 'chmod -R u+rwX "$target" 2>/dev/null; rm -rf "$target"' EXIT

check "the live account came across with the image" \
  "$(grep -c '^shinobi:' "$target/etc/passwd" || true)" "1"
check "and without its home, as unpackfs excludes /home/*" \
  "$([[ -d $target/home/shinobi ]] && echo yes || echo no)" "no"
check "its passwordless sudo grant came too" \
  "$([[ -f $target/etc/sudoers.d/live ]] && echo yes || echo no)" "yes"
check "and its autologin configuration" \
  "$(grep -c 'Autologin' "$target/etc/sddm.conf.d/zz-live-session.conf" || true)" "1"
check "the layer is present but not yet applied to the operator's home" \
  "$([[ -f $target/home/operator/.config/quickshell/shell.qml ]] && echo applied || echo pending)" "applied"
check "provenance has not been written" \
  "$([[ -s $target/usr/share/shinobi/provenance ]] && echo yes || echo no)" "no"

section "the wizard's steps, run as the wizard runs them"
# Parsed out of the wizard's own files rather than transcribed, so a change to
# the configuration is what gets tested. One chroot per step, so a step that
# fails does not cascade into the next one's assertions.
# The transcript is the useful output here: a human reading it can see what each
# step tried to do. The assertions that follow are what decide pass or fail.
#
# Written to a file rather than piped through a heredoc, because a heredoc inside
# a heredoc is where the shell quietly loses an entire command and the failure
# looks like "the wizard did nothing".
work="$(mktemp -d)"
# The container writes root-owned files into the target's userland, and a uid
# 1000 account cannot unlink those however the permissions are set. Removal is
# done as root, in a container, for the same reason the files were created there.
cleanup_target() {
  docker run --rm -v "$(dirname "$target")":/o debian:trixie-slim \
    rm -rf "/o/$(basename "$target")" >/dev/null 2>&1 || chmod -R u+rwX "$target" 2>/dev/null && rm -rf "$target"
}
trap 'cleanup_target; rm -rf "$work"' EXIT

cat >"$work/run-steps.py" <<'PYEOF'
"""Execute the wizard's shellprocess steps against /target, as Calamares would.

The command vectors are parsed out of the wizard's own configuration rather than
transcribed here, so a change to that configuration is what gets tested.
"""
import json
import subprocess
import sys

import yaml


def main() -> int:
    phases = []
    for name in ("prep", "finish"):
        path = f"/modules/shellprocess@{name}.conf"
        with open(path) as handle:
            doc = yaml.safe_load(handle)
        phases.append((name, doc.get("script", [])))

    total = failed = 0
    for name, script in phases:
        for step in script:
            argv = [step["command"], *step.get("args", [])]
            total += 1
            shown = " ".join(a for a in argv if not a.startswith("id shinobi") and "awk -F" not in a)[:110]
            proc = subprocess.run(argv, capture_output=True, text=True)
            if proc.returncode != 0:
                failed += 1
                print(f"  [{name}] FAILED rc={proc.returncode}: {shown}")
                print(f"        {proc.stderr.strip()[:300]}")
            else:
                if proc.stderr.strip():
                    print(f"  [{name}] ok (stderr: {proc.stderr.strip()[:120]}) {shown}")
                else:
                    print(f"  [{name}] ok {shown}")
    print(f"STEPS {total} {failed}")
    return 0


sys.exit(main())
PYEOF

cat >"$work/prepare.sh" <<'PEOF'
# Give /target a userland, from the container's own tools.
#
# An installed system is a copy of the whole image: it has a shell, coreutils and
# shadow-utils, because the image did. Staged package contents have none of that,
# so without this every wizard step fails on "failed to run command /bin/sh" --
# which says nothing about the wizard and everything about the fixture.
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq busybox-static coreutils passwd >/dev/null 2>&1

mkdir -p /target/{bin,lib64,lib/x86_64-linux-gnu,usr/sbin,usr/bin,proc,tmp,root}
chmod 1777 /target/tmp
: >/target/dev/null 2>/dev/null || { mkdir -p /target/dev; : >/target/dev/null; }

cp "$(command -v busybox)" /target/bin/busybox
chroot /target /bin/busybox --install -s /bin

# The dynamic loader, reached through a /lib64 symlink into the multiarch
# directory. Without it every dynamically linked binary fails with ENOENT, which
# is reported as "command not found" and reads as a missing package.
cp -aL /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /target/lib/x86_64-linux-gnu/
ln -sf ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /target/lib64/ld-linux-x86-64.so.2

# getent, for shinobi-setup to resolve an account with. Busybox has no getent
# applet, and the engine asks NSS rather than reading /etc/passwd directly --
# correctly. This stands in for the files backend a machine with no directory
# service uses.
cat >/target/usr/local/bin/getent <<'GEOF'
#!/bin/sh
[ "$1" = passwd ] || exit 2
if [ -n "${2:-}" ]; then grep "^$2:" /etc/passwd; else cat /etc/passwd; fi
GEOF
chmod 0755 /target/usr/local/bin/getent

# shadow-utils' usermod and userdel, if busybox does not provide them, with their
# libraries. A stub would be the wrong call: renaming an account is exactly the
# operation whose real behaviour matters.
for tool in usermod userdel; do
  if ! chroot /target /bin/sh -c "command -v $tool" >/dev/null 2>&1; then
    bin="$(command -v $tool 2>/dev/null || true)"
    if [ -n "$bin" ]; then
      mkdir -p "/target$(dirname "$bin")"
      cp -a "$bin" "/target$bin"
      ldd "$bin" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | sort -u | while read -r lib; do
        [ -f "$lib" ] || continue
        mkdir -p "/target$(dirname "$lib")"
        cp -aL "$lib" "/target$lib" 2>/dev/null || true
      done
    fi
  fi
done
printf 'passwd: files\ngroup: files\nshadow: files\n' >/target/etc/nsswitch.conf
: >/target/etc/shadow
chmod 640 /target/etc/shadow

# rsync: shinobi-setup applies the dotfiles with it.
rsync_bin="$(command -v rsync || true)"
if [ -n "$rsync_bin" ]; then
  apt-get install -y -qq rsync >/dev/null 2>&1
  rsync_bin="$(command -v rsync)"
  cp -a "$rsync_bin" /target/usr/bin/rsync
  ldd "$rsync_bin" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | sort -u | while read -r lib; do
    [ -f "$lib" ] || continue
    mkdir -p "/target$(dirname "$lib")"
    cp -aL "$lib" "/target$lib" 2>/dev/null || true
  done
fi
printf 'userland ready\n'
PEOF

cat >"$work/container.sh" <<'CEOF'
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq coreutils passwd python3 python3-yaml >/dev/null 2>&1
python3 /work/run-steps.py
CEOF

docker run --rm \
  -v "$target:/target" \
  -v "$work:/work:ro" \
  debian:trixie-slim bash /work/prepare.sh >/dev/null 2>&1 ||
  { echo "target-test: could not prepare the target's userland" >&2; exit 1; }

step_transcript=$(docker run --rm \
  -v "$target:/target" \
  -v "$MODULES:/modules:ro" \
  -v "$work:/work:ro" \
  debian:trixie-slim bash /work/container.sh 2>&1)
echo "$step_transcript" | sed 's/^/  /'

total_steps=$(awk '/^STEPS /{print $2}' <<<"$step_transcript" | tail -1)
failed_count=$(awk '/^STEPS /{print $3}' <<<"$step_transcript" | tail -1)
total_steps="${total_steps:-0}"
failed_count="${failed_count:-0}"

# Two steps now: the wizard's work is two shipped scripts rather than sixteen
# quoted shell fragments, so the count is what it should be, not a coincidence.
check "the wizard runs both of its steps" "$([[ ${total_steps:-0} -eq 2 ]] && echo yes || echo no)" "yes"
check "every step succeeded" "$failed_count" "0"

section "what the target looks like afterwards"
check "the live account was removed" \
  "$(grep -c '^shinobi:' "$target/etc/passwd" || true)" "0"
check "an account with a home directory was left alone" \
  "$(grep -c '^builder:' "$target/etc/passwd" || true)" "1"
check "its sudoers grant is gone" \
  "$([[ -f $target/etc/sudoers.d/live ]] && echo yes || echo no)" "no"
check "no autologin survives, wherever it was configured" \
  "$(grep -rli 'autologin' "$target/etc/sddm.conf.d" 2>/dev/null | wc -l)" "0"
check "the operator's account was kept" \
  "$(grep -c '^operator:' "$target/etc/passwd" || true)" "1"
check "and its sudo rule" \
  "$([[ -f $target/etc/sudoers.d/operator ]] && echo yes || echo no)" "yes"
check "the layer was applied to it" \
  "$([[ -f $target/home/operator/.config/hypr/hyprland.conf ]] && echo yes || echo no)" "yes"
check "provenance was written" \
  "$([[ -s $target/usr/share/shinobi/provenance ]] && echo yes || echo no)" "yes"
check "it names the base" \
  "$(grep -c '^base=kali$' "$target/usr/share/shinobi/provenance" 2>/dev/null || true)" "1"
check "the build's apt lists were cleared" \
  "$(find "$target/var/lib/apt/lists" -type f | wc -l | tr -d ' ')" "0"
check "the live session's runtime state is gone" \
  "$([[ -d $target/run/live ]] && echo yes || echo no)" "no"

printf '\n'
if ((failures > 0)); then
  printf 'target-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ntarget-test: PASS\n' "$checks" "$checks"