#!/usr/bin/env bash
# What the operator sees, and what it does not say.
#
# Shinobi is a layer on Kali and says so. What it must not do is present Kali as
# the product: "Kali" in a product name, a window title, a boot menu entry or a
# package description is the base distribution advertising itself on the one
# screen where somebody decides what they are installing, and `kali@kali` at a
# login prompt is the rebrand unfinished.
#
# The audit is a token sweep with an explicit allowlist, because the alternative
# -- reading every string by eye -- is the thing that let `kali@kali` survive in
# the first place. Every allowed occurrence has a reason, and the reason is the
# interesting part: almost all of them are places where naming the base is the
# correct thing to do.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Files an operator can read, or a machine can be identified by. Deliberately
# not the whole repository: source comments explain the relationship to Kali at
# length, and those are for maintainers.
audited=(
  "distro/overlay/bootloaders/bootloaders"
  "packaging/shinobi-installer/etc/calamares/branding"
  "packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/hypr"
  "packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell"
  "distro/overlay/includes.chroot/etc/live"
  "packaging/shinobi-installer/usr/share/applications"
  "packaging/shinobi-core/DEBIAN/control"
  "packaging/shinobi-desktop/DEBIAN/control"
  "packaging/shinobi-installer/DEBIAN/control"
)

# Where naming Kali is correct, and why.
#
# Every entry is path plus a reason, and the reason is the point: a tool that
# cannot explain why it contains the word "kali" is a tool that gets the token
# deleted by someone in a hurry, and then the audit stops meaning anything.
allowlist() {
  case "$1" in
    # The wizard's slide says the base is Kali and unmodified. That is a claim
    # the operator is entitled to make, and hiding it would be worse than
    # stating it.
    */branding/shinobi/show.qml) return 0 ;;
    # live-config's own configuration for the live session: the file sets the
    # account name, and the comment explains why the file exists.
    */config.conf.d/*) return 0 ;;
    # Provenance names the base. That is the entire point of it.
    */shinobi-setup) return 0 ;;
    */control)
      # Package descriptions say what the layer sits on, and the metadata is
      # read by tools rather than by people.
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Comments are stripped before the sweep. A comment is read by a maintainer, and
# there naming the base is exactly what should be written: the relationship to
# Kali is the design, and it needs explaining where somebody will read it. What
# must not happen is Kali being the name an *operator* sees -- in a title, a
# label, a hostname, an account name or a package description.
strip_comments() {
  case "$1" in
    *.cfg | *.cfg.in | *grub.cfg | *.conf | *.desc | *.desktop)
      # Whole-line comments first, then trailing ones: a boot menu and a QML
      # file are mostly comments, and requiring whitespace before the marker
      # misses every one of them.
      sed -e 's/^[[:space:]]*[#;].*$//' -e 's/[[:space:]][#;].*$//' "$1"
      ;;
    *) cat "$1" ;;
  esac
}

# Operator-visible mentions that are correct, with the reason. These are printed
# when the audit runs, so the list cannot rot unnoticed: an allowance nobody
# reads is how a list of exceptions turns into a list of things nobody checks.
# There are none. Kali's own installer used to be allowed here, as a labelled fallback
# on the UEFI menu; it is not on either menu now.
allowed_mentions=()

section "no operator-visible text presents Kali as the product"
for dir in "${audited[@]}"; do
  [[ -d "$ROOT/$dir" ]] || continue
  while IFS= read -r -d '' file; do
    rel="${file#"$ROOT/"}"
    allowlist "$rel" && continue
    grep -Iq . "$file" 2>/dev/null || continue
    survivors=""
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      permitted=false
      for allowance in "${allowed_mentions[@]}"; do
        [[ $line == *"$allowance"* ]] && permitted=true
      done
      $permitted || survivors+="$line"$'\n'
    done < <(strip_comments "$file" | grep -nIE '(^|[^A-Za-z0-9_-])kali([^A-Za-z0-9_-]|$)' || true)
    check "$rel names no 'kali'" "$(printf '%s' "$survivors" | grep -c . || true)" "0"
  done < <(find "$ROOT/$dir" -type f -print0 2>/dev/null)
done

echo
echo "  allowed operator-visible mentions: ${#allowed_mentions[@]}"
for allowance in ${allowed_mentions[@]+"${allowed_mentions[@]}"}; do
  echo "    $allowance"
done
section "the boot menu leads with Shinobi"
grub="$ROOT/distro/overlay/bootloaders/bootloaders/grub-pc/grub.cfg"
syslinux="$ROOT/distro/overlay/bootloaders/bootloaders/syslinux_common/shinobi-installer.cfg"
menu="$ROOT/distro/overlay/bootloaders/bootloaders/syslinux_common/menu.cfg"

check "the GRUB menu offers the installer" \
  "$(grep -c 'menuentry "Install Shinobi OS"' "$grub" || true)" "1"
check "the GRUB installer entry is reachable without the Advanced submenu" \
  "$(awk '/^submenu/{inmenu=1} /menuentry "Install Shinobi OS"/{if (!inmenu) print "yes"}' "$grub" | wc -l)" "1"
check "the syslinux menu includes our entries" \
  "$(grep -c 'include shinobi-installer.cfg' "$menu" || true)" "1"
check "the syslinux installer entry is labelled as Shinobi's" \
  "$(grep -c 'menu label \^Install Shinobi OS' "$syslinux" || true)" "1"
live_in="$ROOT/distro/overlay/bootloaders/bootloaders/syslinux_common/live.cfg.in"
# Executable lines only: these files explain at length why the Kali entries are gone.
menu_code() { grep -vE '^[[:space:]]*#' "$@"; }
check "neither menu offers Kali's own installer (it installs plain Kali, without the layer)" \
  "$(menu_code "$grub" "$menu" | grep -ciE 'kali installer|install_start|install\.cfg|ENABLE_INSTALL_MENU|OPTIONAL_INSTALLER_INCLUDE|Advanced install' || true)" "0"
check "the BIOS live entries are ours, so none boots an account called kali" \
  "$(menu_code "$live_in" | grep -c 'username=kali' || true)" "0"
check "and the persistence and forensic entries name the account Shinobi's way" \
  "$(menu_code "$live_in" | grep -c 'username=shinobi hostname=shinobi' || true)" "3"
check "and no menu points the operator at the base distribution's website" \
  "$(menu_code "$live_in" "$grub" "$menu" "$syslinux" | grep -ci 'kali\.org' || true)" "0"
check "the BIOS template keeps the placeholders live-build fills in (it generates live.cfg from this file)" \
  "$(menu_code "$live_in" | grep -c '@LINUX@' || true)" "5"
check "the ISO is labelled as Shinobi, not as Kali Live (build.sh patches Kali's auto/config)" \
  "$(grep -c -- 's|--iso-volume "Kali Live"|--iso-volume "Shinobi OS"|' "$ROOT/distro/build.sh" || true)" "1"
# The check above only proves the patch is still written in build.sh. It rewrites three
# options of Kali's auto/config by their exact text; if a submodule bump changes the
# quoting or the order, the sed turns into a silent no-op and only a finished ISO shows it.
kali_auto_config="$ROOT/distro/kali-live/auto/config"
if [[ -f $kali_auto_config ]]; then
  check "Kali's auto/config still has the three options build.sh rewrites, each once" \
    "$(grep -cE '^[[:space:]]*--iso-(application "Kali Linux"|publisher "Kali"|volume "Kali Live") \\$' "$kali_auto_config" || true)" "3"
  check "and build.sh patches the application and the publisher as well as the volume" \
    "$(grep -cF -e 's|--iso-application "Kali Linux"|--iso-application "Shinobi OS"|' -e 's|--iso-publisher "Kali"|--iso-publisher "Shinobi OS' "$ROOT/distro/build.sh" || true)" "2"
else
  echo "  skip: distro/kali-live is not checked out, so Kali's auto/config was not compared with the label patch."
fi
check "the installed system's GRUB background is Shinobi's, and the picture ships in shinobi-desktop" \
  "$(bg=$(sed -n 's/^[[:space:]]*GRUB_BACKGROUND:[[:space:]]*"\(.*\)"/\1/p' "$ROOT/packaging/shinobi-installer/etc/calamares/modules/grubcfg.conf"); [[ -n $bg && -s $ROOT/packaging/shinobi-desktop$bg ]] && echo yes || echo no)" "yes"
check "the GRUB menu keeps the live entry" \
  "$(grep -c 'menuentry "Live system (@FLAVOUR_LIVE@ forensic mode)"' "$grub" || true)" "1"

section "the live session is named, not renamed"
# The account is created as shinobi. Kali's live entries pass `username=kali` on
# the kernel command line, and live-config creates the account from *that* in
# preference to the image's configuration files -- so the entries have to say so
# themselves, after Kali's parameters, or the override loses.
check "our GRUB entry names the account" \
  "$(grep -c 'username=shinobi hostname=shinobi' "$grub" || true)" "2"
check "our syslinux entry names the account" \
  "$(grep -c 'username=shinobi hostname=shinobi' "$syslinux" || true)" "2"
check "live-config is configured to create it too, as a second path" \
  "$(grep -qE '^[[:space:]]*LIVE_USERNAME="shinobi"' "$ROOT/distro/overlay/includes.chroot/etc/live/config.conf.d/shinobi.conf" && echo yes || echo no)" "yes"
# live-config reads the files of config.conf.d in name order, so the later name wins. This
# used to compare the two whole paths as strings, which is decided by "overlay" against
# "kali-live" and says yes whatever the files are called.
ours_conf="$ROOT/distro/overlay/includes.chroot/etc/live/config.conf.d/shinobi.conf"
kalis_dir="$ROOT/distro/kali-live/kali-config/common/includes.chroot/etc/live/config.conf.d"
check "our file is the one that wins (it exists, and its name sorts after Kali's kali.conf)" \
  "$([[ -f $ours_conf && $(basename "$ours_conf") > kali.conf ]] && echo yes || echo no)" "yes"
if [[ -d $kalis_dir ]]; then
  check "and Kali's file is still called kali.conf (the comparison above names it)" \
    "$([[ -f $kalis_dir/kali.conf ]] && echo yes || echo no)" "yes"
fi
# The hook does not rename anything. A build chroot has no login account (Kali
# creates its own at boot), so a hook that asked the engine to apply the layer to
# "the" account exited 1 and aborted the build; and the account is created under
# the right name at boot anyway, by the override above. The hook stages the layer
# for an account that does not exist yet.
hook="$ROOT/distro/overlay/kali-config/variant-shinobi/hooks/live/0010-install-layer.chroot"
# (Comment lines are filtered by hand: strip_comments only knows config file
# extensions, and the hook explains itself at length.)
check "the ISO hook stages the layer without an account" \
  "$(grep -v '^[[:space:]]*#' "$hook" | grep -c 'shinobi-setup apply --skel-only' || true)" "1"
check "and renames nothing" \
  "$(grep -v '^[[:space:]]*#' "$hook" | grep -cE 'rename-from|usermod' || true)" "0"

section "the BIOS install entries can actually boot"
# These entries read `linux @LINUX@` and `initrd @INITRD@`, which live-build does not
# substitute in this file, so they shipped literally and the entries did nothing.
check "the BIOS install entries name the kernel by path" \
  "$(grep -cE '^[[:space:]]+linux /live/vmlinuz$' "$syslinux" || true)" "2"
check "and the initrd" "$(grep -cE '^[[:space:]]+initrd /live/initrd.img$' "$syslinux" || true)" "2"
check "no live-build placeholder other than @APPEND_LIVE@ is left in the file" \
  "$(grep -vE '^[[:space:]]*#' "$syslinux" | grep -oE '@[A-Z][A-Z_]*@' | grep -vc '^@APPEND_LIVE@$' || true)" "0"

section "the live session logs itself in to Hyprland"
autologin="$ROOT/distro/overlay/includes.chroot/usr/lib/live/config/0086-shinobi-autologin"
check "the live-config component is shipped, executable, and sorts after live-config's own sddm component" \
  "$([[ -x $autologin ]] && [[ 0086-shinobi-autologin > 0085-sddm ]] && echo yes || echo no)" "yes"
check "it names the Hyprland session" "$(grep -c '^Session=hyprland.desktop$' "$autologin" || true)" "1"
check "it honours noautologin" "$(grep -c 'live-config.noautologin|noautologin)' "$autologin" || true)" "1"

section "the live account gets Kali's groups and shell"
# The sort position is read from the file's own name (a literal compared with a
# literal cannot fail). live-config runs components in name order: the account must
# exist before this runs, and sudo's component must run after it.
usersetup_dir="$ROOT/distro/overlay/includes.chroot/usr/lib/live/config"
usersetup="$(ls "$usersetup_dir"/*-shinobi-user-setup 2>/dev/null | head -1)"
usersetup_name="$(basename "${usersetup:-none}")"
check "the live-config component is shipped and executable" \
  "$([[ -x ${usersetup:-/nonexistent} ]] && echo yes || echo no)" "yes"
check "it sorts after the component that creates the account" \
  "$([[ $usersetup_name > 0030-user-setup ]] && echo yes || echo no)" "yes"
check "and before sudo's, which names the account it configured" \
  "$([[ $usersetup_name < 0040-sudo ]] && echo yes || echo no)" "yes"
check "it adds the account to adm and dialout, among the groups that exist" \
  "$(grep -cE 'for _GROUP in .*adm dialout' "$usersetup" || true)" "1"
check "it honours nozsh" "$(grep -c 'live-config.nozsh|nozsh)' "$usersetup" || true)" "1"
check "and leaves root alone, as 0031 and 0040 do" "$(grep -cE '^[[:space:]]*""[|]root\)' "$usersetup" || true)" "1"

users_conf="$ROOT/packaging/shinobi-installer/etc/calamares/modules/users.conf"
# Executable lines only, and the shell read from under the `user:` map, because that
# is the structure Calamares 3.4.2 reads: a top-level `userShell:` is ignored there and
# this test used to pass on exactly that dead key.
conf_lines() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$users_conf"; }
check "the installed account is in adm" "$(conf_lines | grep -cE '^[[:space:]]+- adm$' || true)" "1"
check "and dialout" "$(conf_lines | grep -cE '^[[:space:]]+- dialout$' || true)" "1"
check "and vboxsf, which the live account is in too" "$(conf_lines | grep -cE '^[[:space:]]+- vboxsf$' || true)" "1"
check "its shell is set under the user: map, the only place Calamares 3.4.2 reads it" \
  "$(conf_lines | awk '/^user:/ {u=1; next} /^[^[:space:]]/ {u=0} u && /^[[:space:]]+shell:[[:space:]]+\/usr\/bin\/zsh$/ {n++} END {print n+0}')" "1"
check "and no top-level userShell key is left, which Calamares ignores" \
  "$(conf_lines | grep -cE '^userShell:' || true)" "0"

section "the wizard is launched from a marker nothing else sets"
# Once per boot entry, counted on the entries themselves: the explanatory comment
# names the marker a third time and is not an entry.
for entry in "$grub" "$syslinux"; do
  check "$(basename "$entry") passes the installer marker on both its entries" \
    "$(strip_comments "$entry" | grep -c 'shinobi\.installer=1' || true)" "2"
done
check "the live session reads it" \
  "$(grep -q 'shinobi-installer-autostart' "$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/hypr/hyprland.conf" && echo yes || echo no)" "yes"
check "the launcher is shipped by the installer package" \
  "$([[ -x $ROOT/packaging/shinobi-installer/usr/lib/shinobi/shinobi-installer-autostart ]] && echo yes || echo no)" "yes"
check "and does nothing when the marker is absent" \
  "$(grep -q 'shinobi.installer=' "$ROOT/packaging/shinobi-installer/usr/lib/shinobi/shinobi-installer-autostart" && echo yes || echo no)" "yes"

section "the wizard is only on the image that can install"
# Calamares belongs to the live image and to shinobi-installer. If it became a
# dependency of shinobi-desktop, every CLI and headless install would carry Qt6
# and the KPM partition libraries for a wizard it will never run.
check "the desktop image installs calamares" \
  "$(grep -qE '^calamares$' "$ROOT/distro/overlay/kali-config/variant-shinobi/package-lists/kali.list.chroot" && echo yes || echo no)" "yes"
check "the console image does not" \
  "$(grep -qE '^calamares$' "$ROOT/distro/overlay/kali-config/variant-shinobi-min/package-lists/kali.list.chroot" && echo yes || echo no)" "no"
check "shinobi-desktop does not depend on it" \
  "$(grep -qE '^Depends:.*calamares' "$ROOT/packaging/shinobi-desktop/DEBIAN/control" && echo yes || echo no)" "no"
check "shinobi-installer does" \
  "$(grep -qE '^Depends:.*calamares' "$ROOT/packaging/shinobi-installer/DEBIAN/control" && echo yes || echo no)" "yes"

printf '\n'
if ((failures > 0)); then
  printf 'branding-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nbranding-test: PASS\n' "$checks" "$checks"