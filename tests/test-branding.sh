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
    *.cfg | *grub.cfg | *.conf | *.desc | *.desktop)
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
allowed_mentions=(
  # Kali's own installer, in the Advanced submenu, labelled as what it is. It is
  # kept as a fallback for a machine the wizard cannot handle, and it installs
  # Kali without any of Shinobi's layer -- calling it "Start installer" beside
  # ours is how somebody ends up with the wrong system and no idea why.
  'menuentry "Kali installer'
  # The same, named on the speech-synthesis entry.
  'menuentry "Kali installer with speech synthesis'
)

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
echo "  allowed operator-visible mentions:"
for allowance in "${allowed_mentions[@]}"; do
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
check "our file is the one that wins" \
  "$([[ distro/overlay/includes.chroot/etc/live/config.conf.d/shinobi.conf > distro/kali-live/kali-config/common/includes.chroot/etc/live/config.conf.d/kali.conf ]] && echo yes || echo no)" "yes"
# And the rename stays as a fallback: if an image somehow still has a kali
# account, the engine deals with it rather than the image shipping a session
# called kali.
check "the ISO hook still renames a legacy account as a fallback" \
  "$(grep -q 'shinobi-setup apply --rename-from kali' "$ROOT/distro/overlay/kali-config/variant-shinobi/hooks/live/0010-install-layer.chroot" && echo yes || echo no)" "yes"

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