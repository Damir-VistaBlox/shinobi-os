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
check "the session can follow the system's keyboard layout (shinobi-keyboard is installed and runs)" sh -c 'test -x /usr/lib/shinobi/shinobi-keyboard && /usr/lib/shinobi/shinobi-keyboard --help >/dev/null'
check "and the skeleton carries the input.conf that hyprland.conf sources" test -f /etc/skel/.config/hypr/input.conf
check "the wizard's setxkbmap stand-in, which carries a chosen layout to the session, is installed" test -x /usr/lib/shinobi/installer-shims/setxkbmap
check "live-config will create the account as shinobi" grep -q '^LIVE_USERNAME="shinobi"' /etc/live/config.conf.d/shinobi.conf
check "Plymouth defaults to the Shinobi theme (hook 0050)" sh -c 'test "$(plymouth-set-default-theme 2>/dev/null)" = shinobi'
check "a Nerd Font is installed (the bar's icons need one; needs network at hook time)" sh -c 'fc-list 2>/dev/null | grep -qi "nerd"'
check "no stray top-level /shinobi-installer from a package that shipped a copy of itself" test ! -e /shinobi-installer
check "the recon server is installed and importable" sh -c 'command -v shinobi-recon >/dev/null && python3 -c "import mcp"'
check "shinobi-setup reports the layer applied" sh -c '/usr/lib/shinobi/shinobi-setup status --json | grep -q "\"dotfiles\":true"'

section "the live session logs itself in (the real live-config, its component and ours)"
# live-config runs its components at a live boot, which a container cannot do, so
# this runs the two that decide the autologin entry by hand, in the order they sort,
# against the real live-config library, and reads the file they leave behind.
if apt-get install -y -qq --no-install-recommends live-config >/dev/null 2>&1; then
  run_autologin() {
    # run_autologin <kernel command line>: leaves /etc/sddm.conf as a live boot would.
    rm -f /etc/sddm.conf /var/lib/live/config/sddm /var/lib/live/config/shinobi-autologin
    mkdir -p /var/lib/live/config
    LIVE_CONFIG_CMDLINE="$1" LIVE_USERNAME=shinobi sh /usr/lib/live/config/0085-sddm >/dev/null 2>&1
    LIVE_CONFIG_CMDLINE="$1" LIVE_USERNAME=shinobi sh /usr/lib/live/config/0086-shinobi-autologin >/dev/null 2>&1
  }
  run_autologin "boot=live components quiet splash noeject username=shinobi"
  check "the autologin entry names the Hyprland session (live-config's own leaves it empty)" grep -qx 'Session=hyprland.desktop' /etc/sddm.conf
  check "and the live account" grep -qx 'User=shinobi' /etc/sddm.conf
  check "our component sorts after live-config's, so its entry is the one that stays" sh -c '[ "0086-shinobi-autologin" \> "0085-sddm" ]'
  run_autologin "boot=live components quiet splash noeject username=shinobi noautologin"
  check "noautologin on the kernel command line still turns autologin off" test ! -e /etc/sddm.conf
  rm -f /etc/sddm.conf

  section "the live account gets Kali's groups and shell (Kali's own component only knows \`kali\`)"
  # 0031-kali-user-setup hard-codes the account name; ours is shinobi, so 0031 finds no
  # such user. 0032 does the same for the account the image actually creates. This runs
  # the real live-config driver with the real 0030-user-setup, which creates the account
  # from the repo's own config.conf.d/shinobi.conf, and then our component, so what is
  # checked is what a live boot would leave. (0031 itself lives in Kali's live-build
  # tree, not here, and is not run: it creates the empty groups kaboxer and wireshark,
  # which this section therefore does not see.)
  apt-get install -y -qq --no-install-recommends user-setup adduser >/dev/null 2>&1 || true
  run_usersetup() {
    # run_usersetup [extra kernel command line words]: a fresh live account, as a boot makes it.
    userdel -r shinobi >/dev/null 2>&1 || true
    rm -f /var/lib/live/config/user-setup /var/lib/live/config/shinobi-user-setup
    mkdir -p /var/lib/live/config
    LIVE_CONFIG_CMDLINE="boot=live components=user-setup,shinobi-user-setup quiet splash noeject $*" \
      /usr/bin/live-config >/dev/null 2>&1
  }
  run_usersetup
  check "live-config created the account named in the repo's config.conf.d" getent passwd shinobi
  check "the account is in adm (read /var/log)" sh -c 'id -nG shinobi | tr " " "\n" | grep -qx adm'
  check "and dialout (serial adapters)" sh -c 'id -nG shinobi | tr " " "\n" | grep -qx dialout'
  check "and still in the groups live-config's own component gives it (audio)" sh -c 'id -nG shinobi | tr " " "\n" | grep -qx audio'
  if [ -x /usr/bin/zsh ]; then
    check "the shell is zsh" sh -c 'test "$(getent passwd shinobi | cut -d: -f7)" = /usr/bin/zsh'
    run_usersetup nozsh
    check "nozsh on the kernel command line keeps bash" sh -c 'test "$(getent passwd shinobi | cut -d: -f7)" = /bin/bash'
    check "and the groups are still added" sh -c 'id -nG shinobi | tr " " "\n" | grep -qx adm'
  else
    bad "zsh is not in the image, so the shell part of the component could not be checked"
  fi
  check "the component sorts after the one that creates the account and before sudo's" \
    sh -c "ls /usr/lib/live/config | sed -n '/^0030-user-setup\$/,/^0040-sudo\$/p' | grep -qx 0032-shinobi-user-setup"
  # Root is never configured, as in 0031 and 0040-sudo: live-config accepts username=root.
  root_shell_before=$(getent passwd root | cut -d: -f7)
  rm -f /var/lib/live/config/shinobi-user-setup
  LIVE_CONFIG_CMDLINE="boot=live username=root" LIVE_USERNAME=root sh /usr/lib/live/config/0032-shinobi-user-setup >/dev/null 2>&1
  check "root's shell is left alone" sh -c "test \"\$(getent passwd root | cut -d: -f7)\" = '$root_shell_before'"
  check "and root is not recorded as configured" test ! -e /var/lib/live/config/shinobi-user-setup
  userdel -r shinobi >/dev/null 2>&1 || true
  rm -f /var/lib/live/config/shinobi-user-setup
  LIVE_CONFIG_CMDLINE="boot=live" LIVE_USERNAME=ghost sh /usr/lib/live/config/0032-shinobi-user-setup >/dev/null 2>&1
  check "an account that does not exist is skipped, and not recorded as done" test ! -e /var/lib/live/config/shinobi-user-setup
else
  bad "could not install live-config to run its components"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  echo "dry-run: PASS ($checks checks)"
else
  echo "dry-run: FAIL ($fails of $checks checks)"
  exit 1
fi
