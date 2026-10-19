#!/usr/bin/env bash
# The Shinobi login screen: an SDDM theme, and what it has to be to be shown at all.
#
# SDDM falls back to its own built-in theme, without a word, when a theme is missing
# a file or fails to load. The operator is then looking at a login screen that is not
# Shinobi's and nothing anywhere says so. So the checks are about the things that make that happen
# (a missing file, a QtQuick import the greeter does not have, a wrong version number in
# metadata.desktop), and about the ways a login screen can fail its one job (leak the
# password, cover the field, render nothing when its settings are unreadable).
#
# The first half reads files. The second half renders every state of the real Main.qml
# offscreen against mock SDDM objects, asserts on the pixels, and drives the theme's own
# login logic (what it asks SDDM to do, what state it is left in); it needs qml6 (Debian:
# qml-qt6, qml6-module-qtquick, qml6-module-qtquick-window; Arch: qt6-declarative) and is
# skipped, loudly, without it.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
THEME="$ROOT/packaging/shinobi-desktop/usr/share/sddm/themes/shinobi"
DROPIN="$ROOT/packaging/shinobi-desktop/usr/lib/sddm/sddm.conf.d/90-shinobi-theme.conf"
SERVICE_DROPIN="$ROOT/packaging/shinobi-desktop/usr/lib/systemd/system/sddm.service.d/10-shinobi-plymouth.conf"

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
# Whole-line comments only: a value may itself contain a '#' (the accent colour does).
conf_lines() { grep -vE '^[[:space:]]*(#|$)' "$1"; }
# The value of KEY in [SECTION] of an INI file, and nothing from anywhere else in it:
# `Current=shinobi` under the wrong header is a setting SDDM never reads.
ini() { conf_lines "$1" | awk -v want="[$2]" -v key="$3" '$0 == want { in_section = 1; next } /^\[/ { in_section = 0 } in_section && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }'; }
# Main.qml without its comments, so a check cannot be satisfied (or tripped) by prose.
qml_code() { grep -vE '^[[:space:]]*//' "$THEME/Main.qml" | sed -e 's|[[:space:]]//.*$||'; }
exists() { [[ -s $1 ]] && echo yes || echo no; }

section "the theme ships what the greeter reads"
for f in Main.qml metadata.desktop theme.conf background.jpg logo.png preview.jpg; do
  check "$f is present" "$(exists "$THEME/$f")" "yes"
done

section "metadata.desktop describes a Qt 6 theme"
meta="$THEME/metadata.desktop"
check "its section is the one SDDM reads (a typo in the header makes SDDM ignore the whole file)" \
  "$(grep -cE '^\[SddmGreeterTheme\]$' "$meta" || true)" "1"
check "it is a theme for the Qt 6 greeter (a Qt 5 theme is not loaded by it)" \
  "$(ini "$meta" SddmGreeterTheme QtVersion)" "6"
check "it names the file SDDM runs" "$(ini "$meta" SddmGreeterTheme MainScript)" "Main.qml"
check "and the settings file" "$(ini "$meta" SddmGreeterTheme ConfigFile)" "theme.conf"
check "and the preview, which exists" \
  "$(p=$(sed -n 's/^Preview=//p' "$meta"); [[ -s $THEME/${p:-none} ]] && echo yes || echo no)" "yes"

section "theme.conf"
conf="$THEME/theme.conf"
check "it names a wallpaper that exists" \
  "$(b=$(conf_lines "$conf" | sed -n 's/^background=//p'); [[ -s $THEME/${b:-none} ]] && echo yes || echo no)" "yes"
check "and an accent that is a colour" \
  "$(conf_lines "$conf" | grep -cE '^accent=#[0-9a-fA-F]{6}$' || true)" "1"

section "Main.qml needs nothing the greeter might not have"
# The greeter runs as an unprivileged user on a minimal image. A theme that imports an
# optional Qt module fails to load there and SDDM shows its fallback instead.
check "it imports QtQuick and nothing else" \
  "$(qml_code | grep -E '^[[:space:]]*import ' | tr -s ' ' | tr '\n' '|')" "import QtQuick|"
check "it never writes to a log or prints (a password typed into the field must not reach one)" \
  "$(qml_code | grep -cE 'console\.[a-z]+|\bprint[[:space:]]*\(' || true)" "0"
check "the password field masks what is typed" \
  "$(qml_code | grep -cE '^[[:space:]]*echoMode:[[:space:]]*TextInput\.Password' || true)" "1"
check "and is not offered to predictive text" \
  "$(qml_code | grep -cE 'ImhNoPredictiveText' || true)" "1"
check "login goes through SDDM, with the chosen account and session" \
  "$(qml_code | grep -cE 'sddm\.login\(currentLogin, password\.text, sessionModel\.lastIndex\)' || true)" "1"
check "the image sizes are sensible (the wallpaper is a JPEG, not the 1.5 MiB PNG)" \
  "$([[ $(file -b "$THEME/background.jpg") == JPEG* && $(stat -c %s "$THEME/background.jpg") -lt 400000 ]] && echo yes || echo no)" "yes"
check "the mark has a transparent background" \
  "$(file -b "$THEME/logo.png" | grep -c 'RGBA' || true)" "1"

section "SDDM is told to use it, and not to cover it"
check "the drop-in selects the theme by its name, in the section SDDM reads it from" \
  "$(ini "$DROPIN" Theme Current)" "shinobi"
check "and turns off the on-screen keyboard, which SDDM defaults to and which covers the password field" \
  "$(conf_lines "$DROPIN" | awk '/^\[General\]/ {g=1; next} /^\[/ {g=0} g && /^InputMethod=$/ {n++} END {print n+0}')" "1"
check "it is in SDDM's vendor layer, so an upgrade never overwrites an operator's own /etc/sddm.conf.d" \
  "$([[ $DROPIN == */usr/lib/sddm/sddm.conf.d/* ]] && echo yes || echo no)" "yes"
check "SDDM is started after Plymouth has quit (else it takes tty2 and the screen stays blank until Ctrl-Alt-F2)" \
  "$(ini "$SERVICE_DROPIN" Unit After)" "plymouth-quit.service"
check "and only ordered, never made to depend on it, and never on the wait unit (no timeout: a stuck splash would block the login screen for good)" \
  "$(conf_lines "$SERVICE_DROPIN" | grep -cE '^(Requires|Wants|BindsTo|PartOf)=|plymouth-quit-wait' || true)" "0"
check "the installer's finalise step cannot delete the selection (it only touches /etc/sddm.conf.d)" \
  "$(grep -c '/usr/lib/sddm' "$ROOT/packaging/shinobi-installer/usr/lib/shinobi/shinobi-install-finalise" || true)" "0"
check "the old hook that edited Kali's Breeze theme is gone (it never applied to the installed system's theme)" \
  "$([[ -e $ROOT/distro/overlay/kali-config/variant-shinobi/hooks/live/0040-login-theme.chroot ]] && echo present || echo gone)" "gone"

section "it renders, in every state, from the real Main.qml"
if command -v qml6 >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if python3 -P "$ROOT/tests/sddm-theme-render.py" "$THEME"; then
    check "the rendered frames are what the theme promises" "ok" "ok"
  else
    check "the rendered frames are what the theme promises" "failed (see above)" "ok"
  fi
else
  echo "  skip: qml6 is not installed, so the theme was not rendered and its login logic was not run."
  echo "        The file checks above ran; the pixel and behaviour checks did not."
  echo "        (Debian/Kali: qml-qt6 qml6-module-qtquick qml6-module-qtquick-window; Arch: qt6-declarative.)"
fi

printf '\n'
if ((failures > 0)); then
  printf 'sddm-theme-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nsddm-theme-test: PASS\n' "$checks" "$checks"
