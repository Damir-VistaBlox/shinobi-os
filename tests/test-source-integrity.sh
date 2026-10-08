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
grep -Fq 'shinobi-theme set' "$ROOT/packaging/shinobi-core/usr/bin/shinobi-session" \
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

# A unit that hardens its filesystem and names a %t/... path in ReadWritePaths
# must also declare RuntimeDirectory for that path, or it can never start.
#
# ProtectSystem=strict works by bind-mounting each ReadWritePaths entry, and a
# bind mount of a path that does not exist fails the unit at step NAMESPACING --
# before ExecStart, so the daemon never runs and never gets to create the
# directory it needs. With RestartSec=2 that is a crash loop, and it is silent
# from the outside: the status bar just says the service is offline.
#
# shinobi-agentd and shinobi-contextd both shipped this way and both crash-looped
# on a live image, where the status bar read "CTX offline" and nothing else
# explained why. RuntimeDirectory= makes systemd create the path first.
for unit in shinobi-agentd.service shinobi-contextd.service; do
  path="$ROOT/packaging/shinobi-core/usr/lib/systemd/user/$unit"
  grep -Eq '^ProtectSystem=strict$' "$path" \
    || continue  # without ProtectSystem the ReadWritePaths bind is not fatal
  runtime_dirs="$(sed -n 's/^RuntimeDirectory=//p' "$path" | tr ' ' '\n' | grep -v '^$' || true)"
  for rw in $(sed -n 's/^ReadWritePaths=//p' "$path" | tr ' ' '\n' | grep -v '^$'); do
    case "$rw" in
      %t/*)
        leaf="${rw#%t/}"
        grep -qxF "$leaf" <<<"$runtime_dirs" \
          || fail "$unit names '$rw' in ReadWritePaths without RuntimeDirectory=$leaf; systemd bind-mounts that path before ExecStart and a missing one fails the unit at NAMESPACING"
        ;;
    esac
  done
done
[[ -s "$ROOT/packaging/shinobi-core/usr/lib/systemd/user/shinobi-desktop.target" ]] \
  || fail "missing Shinobi desktop target"
grep -Fq 'Wants=shinobi-migrate.service shinobi-shell.service shinobi-agentd.service shinobi-contextd.service' \
  "$ROOT/packaging/shinobi-core/usr/lib/systemd/user/shinobi-desktop.target" \
  || fail "desktop target does not group core services"

echo "== Checking nothing is shipped by two packages at once =="
# The .deb (packaging/) and the ISO overlay (distro/overlay/) each install a
# copy of the same user units to the same paths, so whichever is applied last
# wins. The two copies had already drifted in their After= ordering and
# nothing noticed, which is precisely the failure this check exists to catch.
# A unit may exist in only one place; where both exist they must be identical.
packaged_units="$ROOT/packaging/shinobi-core/usr/lib/systemd/user"
overlay_units="$ROOT/distro/overlay/includes.chroot/etc/systemd/user"

# The check this replaces compared the two copies while tolerating either being
# absent -- so once the overlay copies were removed, it quietly tested nothing.
# Duplication is now structurally impossible: the overlay is empty, and a unit
# placed back there would be a second copy at the same path, which is what made
# the RuntimeDirectory fix a two-file edit.
if [[ -d "$overlay_units" ]] && [[ -n "$(find "$overlay_units" -maxdepth 1 -type f \( -name '*.service' -o -name '*.target' \) -print -quit)" ]]; then
  fail "the image overlay carries systemd user units, which the shinobi-core package also ships; one copy, or the two drift again"
fi

# And no two packages may claim the same installed path.
#
# dpkg refuses to unpack a second package over a file the first owns -- "trying
# to overwrite ..., which is also in package shinobi-core" -- and it refuses
# *after* dependency resolution and the postinst, so the cost is an image build
# that gets all the way through live-build first. shinobi-setup was in all three
# packages for exactly this reason and every test passed, because the check
# compared the package skeletons under packaging/ and the engine is added by
# build-deb.sh at build time. So this compares what the packages actually ship,
# by staging them.
declare -A seen_paths=()
collision=0
for pkg in core desktop installer; do
  [[ -f "$ROOT/packaging/shinobi-$pkg/DEBIAN/control" ]] || continue
  pkg_stage="$(mktemp -d)"
  if "$ROOT/packaging/build-deb.sh" "$pkg" --stage "$pkg_stage" >/dev/null 2>&1; then
    while IFS= read -r -d '' shipped; do
      rel="${shipped#"$pkg_stage/"}"
      case "$rel" in DEBIAN/*) continue ;; esac
      # Symlinks are names, not ownership: one package may point at another's file.
      [[ -L $shipped ]] && continue
      if [[ -n "${seen_paths[$rel]:-}" ]]; then
        fail "shinobi-$pkg ships $rel, which ${seen_paths[$rel]} already ships; dpkg cannot own one path twice"
        collision=1
      fi
      seen_paths["$rel"]="shinobi-$pkg"
    done < <(find "$pkg_stage" \( -type f -o -type l \) -print0)
  else
    fail "shinobi-$pkg could not be staged, so its paths were not checked"
  fi
  chmod -R u+rwX "$pkg_stage" 2>/dev/null
  rm -rf "$pkg_stage"
done
(( collision == 0 )) || true

echo "== Checking optional static analyzers =="
if command -v qmllint >/dev/null 2>&1; then
  qmllint "$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell/shell.qml"
else
  echo "source-test: qmllint unavailable; QML syntax deferred to image runtime"
fi

echo "source-integrity-test: PASS"
