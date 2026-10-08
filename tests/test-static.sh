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

echo "== Checking Shinobi control-plane commands =="
for command in version config hook system package update snapshot bar shellctl plugin install agent-profile approval context event tool webapp evidence; do
  [[ -x "$ROOT/bin/shinobi-$command" ]] || fail "missing control-plane command: shinobi $command"
done

[[ -f "$ROOT/libexec/shinobi/shinobi-agentd" ]] || fail 'missing agent daemon'
[[ -f "$ROOT/libexec/shinobi/shinobi-agentctl" ]] || fail 'missing agent client'
[[ -f "$ROOT/libexec/shinobi/shinobi-contextd" ]] || fail 'missing context daemon'
[[ -f "$ROOT/libexec/shinobi/shinobi-contextctl" ]] || fail 'missing context client'
# The Polkit action policy is deliberately absent: it declared org.shinobi.*
# actions that no code ever invoked, so it authorised nothing while reading as
# a privilege control. See the comment in doctor_privilege_boundary.
[[ ! -e "$ROOT/packaging/shinobi-core/usr/share/polkit-1/actions/org.shinobi.policy" ]] \
  || fail 'the dead Polkit action policy is back; it authorises nothing'
# Nothing shinobi ships may be setuid or setgid: privilege comes from the
# distribution's own policy, not from a binary that can act as root.
setuid_shipped="$(find "$ROOT/bin" "$ROOT/libexec" -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null || true)"
[[ -z "$setuid_shipped" ]] || fail "setuid/setgid file shipped: $setuid_shipped"
python3 -m py_compile "$ROOT"/libexec/shinobi/shinobi_control/*.py \
  "$ROOT"/libexec/shinobi/shinobi_control/llm/*.py \
  "$ROOT/libexec/shinobi/shinobi-agentd" "$ROOT/libexec/shinobi/shinobi-agentctl" \
  "$ROOT/libexec/shinobi/shinobi-contextd" "$ROOT/libexec/shinobi/shinobi-contextctl" \
  "$ROOT/libexec/shinobi/shinobi-llmctl" \
  "$ROOT"/mcp-servers/shinobi-recon/shinobi_recon/*.py

echo "== Checking Hyprland theme bootstrap =="
colors_file="$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/hypr/colors.conf"
[[ -f "$colors_file" && ! -L "$colors_file" ]] \
  || fail "default Hyprland colors.conf must be a regular fallback file"
grep -Fq '$active_border = rgba(' "$colors_file" \
  || fail "default active border color is missing"
grep -Fq '$inactive_border = rgba(' "$colors_file" \
  || fail "default inactive border color is missing"
for fallback in \
  "$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/kitty/colors.conf" \
  "$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/wofi/colors.css" \
  "$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell/Theme.qml"
do
  [[ -f "$fallback" && ! -L "$fallback" ]] \
    || fail "desktop fallback must be a regular file: ${fallback#$ROOT/}"
done

echo "== Checking shell syntax =="
# Lint by declared shebang, not by file extension. Several scripts carry no
# extension at all -- packaging/shinobi-core/usr/lib/shinobi/shinobi-migrate is
# the one that matters most, since shinobi-shell.service Requires= it and a
# syntax error there takes the whole desktop down. This also picks up
# install.sh and distro/build.sh, which the old extension-based find skipped
# entirely because they live outside the bin/overlay/packaging roots.
linted=0
while IFS= read -r -d '' script; do
  IFS= read -r first_line <"$script" 2>/dev/null || first_line=""
  case "$first_line" in
    '#!/bin/sh' | '#!/usr/bin/env sh') sh -n "$script" || fail "shell syntax error: ${script#$ROOT/}" ;;
    '#!/bin/bash' | '#!/usr/bin/env bash') bash -n "$script" || fail "shell syntax error: ${script#$ROOT/}" ;;
    *) continue ;;
  esac
  linted=$((linted + 1))
done < <(find "$ROOT" -name .git -prune -o -name kali-live -prune -o -type f -print0)
((linted > 0)) || fail 'no shell scripts found to lint'

echo "== Checking systemd unit syntax =="
if command -v systemd-analyze >/dev/null 2>&1; then
  # The host running this source-level test does not contain the image's
  # package-provided ExecStart binaries (quickshell, shinobi-migrate), so
  # systemd-analyze reports those as missing. Drop exactly those lines and
  # fail on everything else.
  #
  # This used to discard the entire diagnostic blob whenever any one expected
  # line appeared anywhere in it, which meant one missing-ExecStart warning
  # silently masked every other error in the same run -- all four units took
  # that path, so the check verified nothing at all.
  deferred_re='not executable: No such file or directory|Unit shinobi-[[:alnum:]-]+\.(service|target) not found|Failed to create shinobi-[[:alnum:]-]+\.service'
  while IFS= read -r -d '' unit; do
    unit_output="$(systemd-analyze verify "$unit" 2>&1)" || unit_status=$?
    unit_status="${unit_status:-0}"
    unexpected="$(printf '%s\n' "$unit_output" | grep -Ev "$deferred_re" | grep -v '^[[:space:]]*$' || true)"
    if [[ -n "$unexpected" ]]; then
      printf '%s\n' "$unexpected" >&2
      if [[ "$unit_status" -eq 0 ]]; then unit_status=1; fi
      exit "$unit_status"
    fi
    if [[ "$unit_status" -ne 0 ]]; then
      echo "static-test: deferred image-only executable check for $(basename "$unit")"
    fi
    unset unit_status
  done < <(find "$ROOT/packaging" "$ROOT/distro/overlay" -type f \( -name '*.service' -o -name '*.target' \) -print0)
else
  echo "static-test: systemd-analyze unavailable; unit verification skipped"
fi

echo "static-test: PASS"
