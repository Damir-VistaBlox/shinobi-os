#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "source-test: $*" >&2; exit 1; }

echo "== Checking theme completeness =="
for theme in "$ROOT"/themes/*; do
  [[ -d "$theme" ]] || continue
  for file in hypr.conf kitty.conf wofi.css quickshell.qml; do
    [[ -s "$theme/$file" ]] || fail "theme $(basename "$theme") is missing $file"
  done
  [[ -s "$theme/theme.toml" ]] || fail "theme $(basename "$theme") is missing theme.toml"
  grep -Eq '^id[[:space:]]*=' "$theme/theme.toml" || fail "theme $(basename "$theme") has no manifest id"
  grep -Eq '^\$active_border[[:space:]]*=[[:space:]]*rgba\(' "$theme/hypr.conf" \
    || fail "theme $(basename "$theme") has no active border color"
  grep -Eq '^\$inactive_border[[:space:]]*=[[:space:]]*rgba\(' "$theme/hypr.conf" \
    || fail "theme $(basename "$theme") has no inactive border color"
done

echo "== Checking overlay links and permissions =="
broken="$(find -L "$ROOT/distro/overlay" -type l -print -quit)"
[[ -z "$broken" ]] || fail "broken overlay symlink: $broken"
while IFS= read -r -d '' executable; do
  [[ -x "$executable" ]] || fail "packaged executable is not executable: ${executable#$ROOT/}"
done < <(find "$ROOT/packaging" -path '*/DEBIAN/*' -prune -o -type f -path '*/usr/bin/*' -print0)

echo "== Checking theme-switch contract =="
grep -Fq 'ln -sfn "$theme_dir/hypr.conf" "$HOME/.config/hypr/colors.conf"' "$ROOT/bin/shinobi-theme" \
  || fail "shinobi-theme does not update Hyprland colors"
grep -Fq 'shinobi-theme set' "$ROOT/distro/overlay/includes.chroot/usr/local/bin/shinobi-session" \
  || fail "session bootstrap does not apply the persisted theme"

echo "== Checking GRUB menu color syntax =="
grub_theme="$ROOT/distro/overlay/bootloaders/bootloaders/grub-pc/theme.cfg"
grep -Eq '^set color_normal=[[:alnum:]-]+/[[:alnum:]-]+$' "$grub_theme" \
  || fail "GRUB normal color must use named foreground/background colors"
grep -Eq '^set color_highlight=[[:alnum:]-]+/[[:alnum:]-]+$' "$grub_theme" \
  || fail "GRUB highlight color must use named foreground/background colors"
! grep -Eq '^set color_(normal|highlight)=#[0-9a-fA-F]{6}' "$grub_theme" \
  || fail "GRUB menu colors must not use unsupported hex values"

echo "== Checking service ownership contract =="
for unit in shinobi-migrate.service shinobi-shell.service shinobi-agentd.service shinobi-contextd.service; do
  path="$ROOT/packaging/shinobi-core/usr/lib/systemd/user/$unit"
  [[ -s "$path" ]] || fail "missing packaged user unit: $unit"
  grep -Eq '^Description=' "$path" || fail "$unit has no Description"
  grep -Eq '^ExecStart=' "$path" || fail "$unit has no ExecStart"
done
grep -Fq 'Requires=shinobi-migrate.service' \
  "$ROOT/packaging/shinobi-core/usr/lib/systemd/user/shinobi-shell.service" \
  || fail "shell service does not require migrations"
[[ -s "$ROOT/packaging/shinobi-core/usr/lib/systemd/user/shinobi-desktop.target" ]] \
  || fail "missing Shinobi desktop target"
grep -Fq 'Wants=shinobi-migrate.service shinobi-shell.service shinobi-agentd.service shinobi-contextd.service' \
  "$ROOT/packaging/shinobi-core/usr/lib/systemd/user/shinobi-desktop.target" \
  || fail "desktop target does not group core services"

echo "== Checking optional static analyzers =="
if command -v qmllint >/dev/null 2>&1; then
  qmllint "$ROOT/distro/overlay/includes.chroot/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell/shell.qml"
else
  echo "source-test: qmllint unavailable; QML syntax deferred to image runtime"
fi

echo "source-integrity-test: PASS"
