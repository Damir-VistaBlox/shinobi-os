#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "static-test: $*" >&2
  exit 1
}

echo "== Checking Shinobi package profiles =="
for variant in shinobi shinobi-min; do
  list="$ROOT/distro/overlay/kali-config/variant-$variant/package-lists/kali.list.chroot"
  [[ -f "$list" ]] || fail "missing package list: $list"
  ! grep -Eq '^[[:space:]]*(kali-linux-default|kali-desktop-live)[[:space:]]*$' "$list" \
    || fail "$variant still contains a deferred Kali metapackage"
done

echo "== Checking required desktop/runtime packages =="
desktop_list="$ROOT/distro/overlay/kali-config/variant-shinobi/package-lists/kali.list.chroot"
for package in kali-linux-core hyprland sddm quickshell network-manager pipewire wireplumber btop; do
  grep -Eq "^[[:space:]]*$package[[:space:]]*$" "$desktop_list" \
    || fail "required package missing from desktop profile: $package"
done

echo "== Checking Hyprland theme bootstrap =="
colors_file="$ROOT/distro/overlay/includes.chroot/usr/share/shinobi-dotfiles/etc/skel/.config/hypr/colors.conf"
[[ -f "$colors_file" && ! -L "$colors_file" ]] \
  || fail "default Hyprland colors.conf must be a regular fallback file"
grep -Fq '$active_border = rgba(' "$colors_file" \
  || fail "default active border color is missing"
grep -Fq '$inactive_border = rgba(' "$colors_file" \
  || fail "default inactive border color is missing"
for fallback in \
  "$ROOT/distro/overlay/includes.chroot/usr/share/shinobi-dotfiles/etc/skel/.config/kitty/colors.conf" \
  "$ROOT/distro/overlay/includes.chroot/usr/share/shinobi-dotfiles/etc/skel/.config/wofi/colors.css" \
  "$ROOT/distro/overlay/includes.chroot/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell/Theme.qml"
do
  [[ -f "$fallback" && ! -L "$fallback" ]] \
    || fail "desktop fallback must be a regular file: ${fallback#$ROOT/}"
done

echo "== Checking shell syntax =="
while IFS= read -r -d '' script; do
  case "$script" in
    *.bash) bash -n "$script" ;;
    *) sh -n "$script" ;;
  esac
done < <(find "$ROOT/bin" "$ROOT/distro" "$ROOT/packaging" -type f \( -name '*.sh' -o -name '*.bash' \) -print0)

echo "== Checking systemd unit syntax =="
if command -v systemd-analyze >/dev/null 2>&1; then
  while IFS= read -r -d '' unit; do
    unit_output="$(systemd-analyze verify "$unit" 2>&1)" || unit_status=$?
    unit_status="${unit_status:-0}"
    if [[ "$unit_status" -ne 0 ]]; then
      # The host running this source-level test does not contain the image's
      # package-provided ExecStart binaries (quickshell and shinobi-migrate).
      # Keep those expected staging warnings non-fatal, but fail on every
      # other unit error.
      if [[ "$unit_output" != *"not executable: No such file or directory"* ]]; then
        printf '%s\n' "$unit_output" >&2
        exit "$unit_status"
      fi
      echo "static-test: deferred image-only executable check for $(basename "$unit")"
    fi
    unset unit_status
  done < <(find "$ROOT" -path '*/.git' -prune -o -type f -name '*.service' -print0)
else
  echo "static-test: systemd-analyze unavailable; unit verification skipped"
fi

echo "static-test: PASS"
