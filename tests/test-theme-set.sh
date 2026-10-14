#!/usr/bin/env bash
# Tests that `shinobi-theme set` finishes cleanly, for every theme that ships.
#
# It ended in an undefined function. The script calls shinobi_emit_event, which
# lives in _shinobi-common.sh, and never sourced that file -- so after doing all
# of its work (repointing the colour links, recording the theme) it died with
# exit 127 on its second-to-last line, before telling the operator the theme was
# set. By hand that reads as an error after a success. At login it is worse:
# shinobi-session runs `shinobi-theme set` with its output discarded and reports
# "could not apply theme" every time, for a theme that had been applied. And
# theme.changed was never published.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

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

home="$work/home"
mkdir -p "$home"

# Everything the command touches is this test's own: the home it links into, the
# hook roots (so no operator hook runs), and the runtime directory events land
# in. env -i also drops HYPRLAND_INSTANCE_SIGNATURE and WAYLAND_DISPLAY, so the
# command never tries to reload a compositor or restart a service that is not
# there.
sandboxed() {
  env -i PATH="$ROOT/bin:$PATH" HOME="$home" \
    XDG_RUNTIME_DIR="$work/run" XDG_STATE_HOME="$work/state" \
    SHINOBI_THEMES_DIR="$ROOT/themes" \
    SHINOBI_SYSTEM_HOOKS="$work/hooks-system" SHINOBI_USER_HOOKS="$work/hooks-user" \
    "$@"
}

themes=()
for dir in "$ROOT"/themes/*/; do
  themes+=("$(basename -- "$dir")")
done
check "the themes that ship are found" "$([[ ${#themes[@]} -ge 2 ]] && echo yes || echo no)" "yes"

for theme in "${themes[@]}"; do
  echo "== shinobi-theme set $theme =="
  rc=0
  out="$(sandboxed "$ROOT/bin/shinobi-theme" set "$theme" 2>&1)" || rc=$?
  check "exits 0" "$rc" "0"
  check "tells the operator it worked" "$(grep -c "^Theme set to: $theme" <<<"$out" || true)" "1"
  check "records the theme" "$(sandboxed "$ROOT/bin/shinobi-theme" current)" "$theme"
  check "repoints the Hyprland colours" \
    "$(readlink "$home/.config/hypr/colors.conf")" "$ROOT/themes/$theme/hypr.conf"
done

echo "== the change is published =="
# Through the real shinobi-event, so this fails if the event never gets that far
# and not only if the helper was called.
published="$(sandboxed "$ROOT/bin/shinobi-event" recent | python3 -c '
import json, sys
print(" ".join(e["payload"]["theme"] for e in json.load(sys.stdin) if e["event"] == "theme.changed"))
')"
check "theme.changed was published once per set, in order" "$published" "${themes[*]}"

echo "== bad input is still refused, and not by a crash =="
rc=0
sandboxed "$ROOT/bin/shinobi-theme" set no-such-theme >/dev/null 2>&1 || rc=$?
check "an unknown theme exits 1" "$rc" "1"
rc=0
sandboxed "$ROOT/bin/shinobi-theme" set '../escape' >/dev/null 2>&1 || rc=$?
check "an invalid name exits 2" "$rc" "2"

echo
if ((failures > 0)); then
  printf 'theme-set-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ntheme-set-test: PASS\n' "$checks" "$checks"
