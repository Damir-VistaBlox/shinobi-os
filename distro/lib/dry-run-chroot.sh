#!/bin/bash
# The inside half of distro/dry-run-hooks.sh. Runs as root in a kali-rolling
# container with the checkout mounted read-only at /repo.
#
# It reproduces, as closely as a container can, what the ISO build does to the
# chroot before squashing it: stage the sources the way distro/build.sh does, lay
# the overlay's includes.chroot over the root, install the variant's package list,
# then run the variant's live hooks in order and stop at the first failure (as
# live-build does). Then it checks the resulting root against the same
# expectations tests/test-image-content.sh holds the finished ISO to, plus the
# ones that matter for installing and logging in.
#
# What it does not reproduce: Kali's own hooks (kali-hacks.chroot) and Kali's
# common package lists (firmware, drivers, microcode), a kernel, systemd, and live-config running at boot. It also installs without Recommends by
# default, which live-build does not (nothing in this repo turns them off): pass
# --with-recommends to match, at the cost of several hundred more packages. A
# failure here is a failure the real build would very likely also hit; a pass is
# not a proof that the ISO builds.
set -uo pipefail

VARIANT="${1:-shinobi}"
CONTINUE=""
RECOMMENDS="--no-install-recommends"
for flag in "${@:2}"; do
  case "$flag" in
    --continue) CONTINUE="--continue" ;;
    --with-recommends) RECOMMENDS="" ;;
    "") ;;
    *) echo "dry-run: unknown argument" >&2; exit 64 ;;
  esac
done
REPO=/repo
VARIANT_DIR="$REPO/distro/overlay/kali-config/variant-$VARIANT"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

fails=0
checks=0
ok() { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); printf '  FAIL %s\n' "$1"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

[ -d "$VARIANT_DIR" ] || { echo "dry-run: no such variant: $VARIANT" >&2; exit 2; }

section "the container"
# A container has no init to start services, and a postinst that tries should be
# refused the way live-build's chroot refuses it.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
# Keep downloaded packages, so a rerun against the same cache does not fetch them again.
rm -f /etc/apt/apt.conf.d/docker-clean
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/99keep
apt-get update -qq 2>&1 | tail -2
# The harness needs rsync to stage; the image has it from the package list.
apt-get install -y -qq --no-install-recommends rsync >/dev/null 2>&1 || bad "could not install rsync, which this harness needs"

section "staging, as distro/build.sh does it"
# The list of staged directories is read out of build.sh itself, so this cannot
# drift from what the build copies.
staged=$(awk '/rsync -a "\$ROOT\/bin"/,/\$STAGE\//' "$REPO/distro/build.sh" | grep -oE '"\$ROOT/[a-z-]+"' | sed -E 's|"\$ROOT/([a-z-]+)"|\1|')
if [ -z "$staged" ]; then
  bad "could not read the staged directories out of distro/build.sh"
  exit 1
fi
mkdir -p /opt/shinobi
# Not owned by whoever owns the checkout: the files belong to root in the image, and
# a host uid leaking in would make this behave differently from the build.
staged_ok=true
for dir in $staged; do rsync -a --no-owner --no-group "$REPO/$dir" /opt/shinobi/ || staged_ok=false; done
if $staged_ok; then ok "staged into /opt/shinobi: $(echo $staged)"; else bad "staging into /opt/shinobi failed"; fi
# tar, not rsync -a or cp -a: those apply the source directory's owner and mode to
# the directories they copy into, which here would hand / and /etc to the host
# user and make every root-owned postinst after it fail. --no-overwrite-dir leaves
# existing directories as they are.
# --exclude=./opt/shinobi: build.sh deletes and regenerates the overlay's own opt/shinobi
# (gitignored) on every build. A copy left there by an earlier build would overwrite
# the freshly staged sources above, and the dry run would test the previous build's.
if tar -C "$REPO/distro/overlay/includes.chroot" --exclude=./opt/shinobi -cf - . | tar -C / -xf - --no-same-owner --no-overwrite-dir; then
  ok "overlay includes.chroot applied (/ and /etc left as they were)"
else
  bad "applying the overlay's includes.chroot failed"
fi
check "/ and /etc are still root's" sh -c '[ "$(stat -c %u /)" = 0 ] && [ "$(stat -c %u /etc)" = 0 ]'

section "the variant's package list ($VARIANT)"
packages=$(grep -v '^[[:space:]]*#' "$VARIANT_DIR/package-lists/kali.list.chroot" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
if apt-get install -y -qq $RECOMMENDS $packages >/tmp/packages.log 2>&1; then
  ok "installed: $(echo "$packages" | wc -w) requested packages"
else
  bad "installing the package list failed"
  echo "     ---- what dpkg objected to ----"
  grep -E "dpkg: error processing|Errors were caused by|^E: |cannot|failed|Failed" /tmp/packages.log | head -20 | sed 's/^/     | /'
  echo "     ---- last lines ----"
  tail -12 /tmp/packages.log | sed 's/^/     | /'
fi

section "the live hooks, in order"
mkdir -p /tmp/hooks
hooks_ok=true
for src in "$VARIANT_DIR"/hooks/live/*.chroot; do
  name=$(basename "$src")
  cp "$src" "/tmp/hooks/$name"
  chmod +x "/tmp/hooks/$name"
  if (cd / && "/tmp/hooks/$name") >"/tmp/hook-$name.log" 2>&1; then
    ok "$name"
  else
    rc=$?
    bad "$name exited $rc"
    echo "     ---- last lines of its output ----"
    tail -25 "/tmp/hook-$name.log" | sed 's/^/     | /'
    hooks_ok=false
    if [ "$CONTINUE" != "--continue" ]; then
      echo "     live-build stops at the first failing hook, and so does this. (--continue to run on.)"
      break
    fi
  fi
done

if [ "$VARIANT" != shinobi ]; then
  section "the result"
  echo "  (the post-hook checks are written for the desktop variant 'shinobi'; for '$VARIANT' only the hooks above were run)"
  printf '\n'
  if [ "$fails" -eq 0 ]; then echo "dry-run: PASS ($checks checks, hooks only)"; exit 0; fi
  echo "dry-run: FAIL ($fails of $checks checks)"
  exit 1
fi

section "the result, held to what the finished ISO is held to"
# The expectations are read out of tests/test-image-content.sh so the two cannot
# disagree about what a correct image is.
IMG_TEST="$REPO/tests/test-image-content.sh"
paths=$(awk '/for path in \\/{f=1;next} f&&/^do$/{exit} f{gsub(/[\\ ]/,""); print}' "$IMG_TEST")
required=$(awk '/for package in kali-linux-core/{ sub(/.*for package in /,""); sub(/; do.*/,""); print; exit}' "$IMG_TEST")
forbidden=$(awk '/for package in kali-linux-default/{ sub(/.*for package in /,""); sub(/; do.*/,""); print; exit}' "$IMG_TEST")
# All three lists, or the harness would quietly check less than the ISO test does.
if [ -z "$paths" ] || [ -z "$required" ] || [ -z "$forbidden" ]; then
  bad "could not read all three expectation lists (paths, required packages, forbidden packages) out of tests/test-image-content.sh"
fi
for p in $paths; do
  if [ -e "$p" ] || [ -L "$p" ]; then ok "path present: $p"; else bad "path missing: $p"; fi
done
for pkg in $required; do
  if [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ]; then ok "package installed: $pkg"; else bad "package not installed: $pkg"; fi
done
for pkg in $forbidden; do
  if [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ]; then bad "package must not be installed: $pkg"; else ok "package absent, as required: $pkg"; fi
done

# The rest of what the ISO test checks that applies to a root filesystem. (Its
# SquashFS-format check does not: there is no SquashFS here.)
check "the top wrapper targets btop" grep -Fq /usr/bin/btop /usr/local/bin/top
check "shinobi-core carries Maintainer metadata" sh -c 'test -n "$(dpkg-query -W -f="\${Maintainer}" shinobi-core 2>/dev/null)"'

section "what installing and logging in need"
for pkg in shinobi-core shinobi-desktop shinobi-installer calamares; do
  if [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ]; then ok "$pkg is in the image"; else bad "$pkg is NOT in the image"; fi
done
check "the session offers only Hyprland (hook 0005)" sh -c 'test "$(ls /usr/share/wayland-sessions | tr "\n" " ")" = "hyprland.desktop "'
check "the layer is staged in /etc/skel for the account created at boot" test -f /etc/skel/.config/hypr/hyprland.conf
check "the provenance file is written" test -s /usr/share/shinobi/provenance
check "live-config will create the account as shinobi" grep -q '^LIVE_USERNAME="shinobi"' /etc/live/config.conf.d/shinobi.conf
check "Plymouth defaults to the Shinobi theme (hook 0050)" sh -c 'test "$(plymouth-set-default-theme 2>/dev/null)" = shinobi'
check "a Nerd Font is installed (the bar's icons need one; needs network at hook time)" sh -c 'fc-list 2>/dev/null | grep -qi "nerd"'
check "no stray top-level /shinobi-installer from a package that shipped a copy of itself" test ! -e /shinobi-installer
check "the recon server is installed and importable" sh -c 'command -v shinobi-recon >/dev/null && python3 -c "import mcp"'
check "shinobi-setup reports the layer applied" sh -c '/usr/lib/shinobi/shinobi-setup status --json | grep -q "\"dotfiles\":true"'

printf '\n'
if [ "$fails" -eq 0 ]; then
  echo "dry-run: PASS ($checks checks)"
else
  echo "dry-run: FAIL ($fails of $checks checks)"
  exit 1
fi
