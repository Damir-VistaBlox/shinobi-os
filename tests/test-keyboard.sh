#!/usr/bin/env bash
# Tests that the wizard, the login screen, the session and the lock screen type the same
# characters.
#
# A password is a sequence of key presses read through whichever layout is active where
# it is read. The installer's Users page sets one through the live session's layout; the
# login screen (an X11 greeter, which reads the layout the wizard wrote to
# /etc/X11/xorg.conf.d/00-keyboard.conf) checks it through the installed system's; and
# hyprlock, which follows whatever layout the compositor has, checks it again later.
# Until this was fixed the first was always `us` (the wizard is a Wayland client, and
# nothing it does with a chosen layout reaches Hyprland) and the third was too
# (hyprland.conf said `kb_layout = us`), so an operator who chose German set a password
# that the login screen read differently, and that the lock screen would not accept.
#
# These tests run the pieces that fix it -- shinobi-keyboard, the wizard's `setxkbmap`
# stand-in, the launcher that puts it on the wizard's PATH -- with a fake hyprctl, so that
# nothing here can touch the compositor of whoever runs them, and then put the whole chain
# against the real xkb library: a password with characters that differ between layouts is
# typed on the layout the operator chose, and read back through what each place ends up
# with.
#
# The Calamares half is a transcription (tests/calamares-keyboard.py) of what v3.4.2 writes
# and runs for a choice, checked against a booted image. That the real Calamares still runs
# `setxkbmap` the way the transcription says is checked where it is already run for real, in
# a container: tests/test-installer.sh.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/packaging/shinobi-desktop/usr/lib/shinobi/shinobi-keyboard"
SHIM="$ROOT/packaging/shinobi-installer/usr/lib/shinobi/installer-shims/setxkbmap"
LAUNCHER="$ROOT/packaging/shinobi-installer/usr/lib/shinobi/shinobi-installer-run"
DOTFILES="$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/hypr"
CONF="$ROOT/packaging/shinobi-installer/etc/calamares"
DECODE="$ROOT/tests/xkb-decode.py"
CALAMARES="$ROOT/tests/calamares-keyboard.py"

# Whatever this is run from, none of it may reach a real compositor.
unset HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY DISPLAY

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf -- "$work"' EXIT

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

# The real xkb library is what "these key presses mean this" is checked against. Without it
# the checks that need it fail, loudly, instead of passing by not running.
have_xkb=yes
xkb_problem="$(python3 -I "$DECODE" type a us 2>&1 >/dev/null | tail -1)" || have_xkb=no
xkb() { python3 -I "$DECODE" "$@"; }

# A PATH of linked system tools and fakes, so the real hyprctl, setxkbmap, setpriv or
# getent of the machine running this are never consulted.
tools="$work/tools"
fake="$work/fake"
log="$work/log"
mkdir -p "$tools" "$fake" "$log"
for tool in sh cat tr wc mkdir mv chmod sed cut id stat dirname env rm; do
  ln -sf "$(command -v "$tool")" "$tools/$tool"
done
real_id="$(command -v id)"
cat >"$fake/hyprctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG/hyprctl"
echo "${FAKE_HYPR_REPLY:-ok}"
EOF
chmod +x "$fake/hyprctl"

# --- one account to run the helper as ----------------------------------------
home="$work/home"
run="$work/run"
sysfile="$work/etc-default-keyboard"
x11file="$work/00-keyboard.conf"
input_conf="$home/.config/hypr/input.conf"

fresh() {
  rm -rf "$home" "$run" "$sysfile" "$x11file" "$log"/*
  mkdir -p "$home" "$run"
  chmod 700 "$run"
}

# helper <args>: shinobi-keyboard, as that account. Sets rc, out, err. HIS=1 puts it in a
# Hyprland session (with the fake hyprctl), as the session starts it.
rc=0
out=""
err=""
helper() {
  rc=0
  env -i PATH="$fake:$tools" HOME="$home" XDG_RUNTIME_DIR="$run" FAKE_LOG="$log" \
    SHINOBI_KEYBOARD_SYSTEM_FILE="$sysfile" SHINOBI_KEYBOARD_X11_FILE="$x11file" \
    ${HIS:+HYPRLAND_INSTANCE_SIGNATURE=test-instance} ${FAKE_HYPR_REPLY:+FAKE_HYPR_REPLY="$FAKE_HYPR_REPLY"} \
    sh "$HELPER" "$@" >"$work/out" 2>"$work/err" || rc=$?
  out="$(<"$work/out")"
  err="$(<"$work/err")"
}
count() { if [[ -e "$log/$1" ]]; then wc -l <"$log/$1" | tr -d ' '; else echo 0; fi; }
field() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" <<<"$out"; }

# What the session was told, as layout|variant|options|model, from input.conf.
applied() {
  [[ -f $input_conf ]] || { echo "(none)"; return; }
  printf '%s|%s|%s|%s' \
    "$(sed -n 's/^  kb_layout = *//p' "$input_conf")" "$(sed -n 's/^  kb_variant = *//p' "$input_conf")" \
    "$(sed -n 's/^  kb_options = *//p' "$input_conf")" "$(sed -n 's/^  kb_model = *//p' "$input_conf")"
}

# The /etc/default/keyboard a real install wrote (Calamares 3.4.2, German, no options).
calamares_de='# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
BACKSPACE="guess"
'

section "the session follows the system's layout"
fresh
helper show
check "with no keyboard file the layout is us, and it says it is the default" \
  "$(head -1 <<<"$out")|$(field XKBLAYOUT)" "source: the default|us"
helper apply
check "applying it writes input.conf" "$rc|$(applied)" "0|us|||pc105"
check "which is exactly the file the dotfiles ship, so a US system changes nothing" \
  "$(cmp -s "$DOTFILES/input.conf" "$input_conf" && echo same || echo differs)" "same"
HIS=1 helper apply
check "an unchanged file does not reload Hyprland" "$rc|$(count hyprctl)" "0|0"

fresh
printf '%s' "$calamares_de" >"$sysfile"
HIS=1 helper apply
check "a German system: the session is given de" "$rc|$(applied)" "0|de|||pc105"
check "Hyprland is asked to reload, once" "$(cat "$log/hyprctl")" "reload"
HIS=1 helper apply
check "and not again while nothing has changed" "$(count hyprctl)" "1"

printf 'XKBMODEL="pc105"\nXKBLAYOUT="fr"\nXKBVARIANT="azerty"\n' >"$sysfile"
HIS=1 helper apply
check "French azerty: the variant comes with it" "$(applied)" "fr|azerty||pc105"
printf '%s' "$calamares_de" >"$sysfile"
HIS=1 helper apply
check "and going back to German clears it (hyprctl keyword cannot say 'empty')" "$(applied)" "de|||pc105"

python3 -I "$CALAMARES" default ru >"$sysfile"
helper apply
check "Russian, as Calamares writes it: us first, Alt+Shift to switch" \
  "$(applied)" "us,ru||grp:alt_shift_toggle|pc105"

section "reading /etc/default/keyboard the way a config file should be read"
read_case() {
  # read_case "description" "file content" "expected layout|variant|options|model"
  fresh
  printf '%b' "$2" >"$sysfile"
  helper apply
  check "$1" "$(applied)" "$3"
}
read_case "unquoted values" 'XKBLAYOUT=de\nXKBMODEL=pc104\n' "de|||pc104"
read_case "single quotes" "XKBLAYOUT='de'\nXKBVARIANT='nodeadkeys'\n" "de|nodeadkeys||"
read_case "Windows line endings" 'XKBLAYOUT="de"\r\nXKBVARIANT="nodeadkeys"\r\n' "de|nodeadkeys||"
read_case "indentation, comments and keys it does not use" \
  '  # a comment\n  XKBLAYOUT="gb"\nBACKSPACE="guess"\n' "gb|||"
read_case "the last assignment wins, as it does when the file is sourced" \
  'XKBLAYOUT="us"\nXKBLAYOUT="it"\n' "it|||"
read_case "a trailing comment after a quoted value" 'XKBLAYOUT="es" # spanish\n' "es|||"
read_case "no final newline" 'XKBLAYOUT="pt"' "pt|||"
read_case "no layout at all means us" 'XKBMODEL="pc105"\nXKBLAYOUT=""\n' "us|||pc105"
check "and nothing is said about it" "$err" ""

section "nothing in that file is ever run, or written through"
payload="$work/PWNED"
hostile() {
  # hostile "description" "file content"
  fresh
  printf '%b' "$2" >"$sysfile"
  helper apply
  check "$1: falls back to us" "$(applied)" "us|||pc105"
  check "$1: warns" "$(grep -c 'ignoring' <<<"$err" || true)" "1"
  check "$1: runs nothing" "$([[ -e $payload ]] && echo ran || echo none)" "none"
  check "$1: writes none of it into the config" \
    "$(grep -c -E 'PWNED|touch|\$|`|;|\.\./' "$input_conf" || true)" "0"
}
hostile "a command after a semicolon" 'XKBLAYOUT="de;touch '"$payload"'"\n'
hostile "command substitution" 'XKBLAYOUT="$(touch '"$payload"')"\n'
hostile "backticks" 'XKBLAYOUT="`touch '"$payload"'`"\n'
hostile "a hyprlang comment character" 'XKBLAYOUT="de # not a comment here"\n'
hostile "a variable reference" 'XKBLAYOUT="$HOME"\n'
hostile "an option with a command in it" 'XKBLAYOUT="de"\nXKBOPTIONS="grp:alt_shift_toggle;touch '"$payload"'"\n'
hostile "a model with a space in it" 'XKBLAYOUT="de"\nXKBMODEL="pc 105"\n'
hostile "an empty entry in the layout list" 'XKBLAYOUT="us,,ru"\n'
hostile "more variants than layouts" 'XKBLAYOUT="de"\nXKBVARIANT=",nodeadkeys"\n'
hostile "a path" 'XKBLAYOUT="../../etc/passwd"\n'

section "a layout the installer chose for this session comes first"
fresh
printf '%s' "$calamares_de" >"$sysfile"
helper set --model pc105 --layout fr --variant azerty --options ""
check "set records it and applies it, over the system's" "$rc|$(applied)" "0|fr|azerty||pc105"
check "in the account's runtime directory, readable by nobody else" \
  "$(stat -c %a "$run/shinobi/keyboard")" "600"
check "as a file keyboard(5) would read" "$(cat "$run/shinobi/keyboard")" \
  'XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT="azerty"
XKBOPTIONS=""'
HIS=1 helper apply
check "a later apply (a login, a reload) does not undo the installer's choice" "$(applied)" "fr|azerty||pc105"
helper show
check "show says where it came from" "$(head -1 <<<"$out" | sed 's|(.*||')" "source: the installer's choice "
rm -f "$run/shinobi/keyboard"
helper apply
check "without it the system's layout is back" "$(applied)" "de|||pc105"

fresh
printf '%s' "$calamares_de" >"$sysfile"
mkdir -p "$run/shinobi"
printf 'XKBLAYOUT="gb;touch x"\n' >"$run/shinobi/keyboard"
helper apply
check "a choice that is not a layout is ignored, with a warning, and the system's is used" \
  "$(applied)|$(grep -c 'ignoring' <<<"$err" || true)" "de|||pc105|1"
printf 'XKBLAYOUT="gb"\n' >"$work/elsewhere"
rm -f "$run/shinobi/keyboard"
ln -s "$work/elsewhere" "$run/shinobi/keyboard"
helper apply
check "and one that is a symbolic link is not followed" "$(applied)" "de|||pc105"

section "set refuses what it cannot do safely"
fresh
helper set --layout 'de;touch x'
check "a layout that is not an xkb name: refused, nothing recorded" \
  "$rc|$([[ -e $run/shinobi/keyboard ]] && echo recorded || echo none)|$([[ -e $input_conf ]] && echo written || echo none)" \
  "2|none|none"
helper set --layout us --variant ',,'
check "more variants than layouts: refused" "$rc" "2"
helper set --model pc105
check "no layout: refused" "$rc" "2"
helper set --layout
check "an option with no value: refused" "$rc" "2"
helper set --bogus x
check "an option it does not have: refused" "$rc" "2"
fresh
mkdir -p "$work/elsewhere-dir"
ln -s "$work/elsewhere-dir" "$run/shinobi"
helper set --layout de
check "a runtime directory that is a symbolic link is not written through" \
  "$rc|$(ls -A "$work/elsewhere-dir" | wc -l | tr -d ' ')" "1|0"
fresh
rm -rf "$run"
helper set --layout de
check "no runtime directory: it says so and fails" "$rc|$(grep -c 'runtime directory' <<<"$err" || true)" "1|1"

section "the reload"
fresh
printf '%s' "$calamares_de" >"$sysfile"
FAKE_HYPR_REPLY="Invalid dispatcher" HIS=1 helper apply
check "Hyprland not answering 'ok': it fails, and says what it said" \
  "$rc|$(grep -c 'Invalid dispatcher' <<<"$err" || true)" "1|1"
check "and the file is written anyway, so the next login has the layout" "$(applied)" "de|||pc105"
fresh
printf '%s' "$calamares_de" >"$sysfile"
rc=0
env -i PATH="$tools" HOME="$home" XDG_RUNTIME_DIR="$run" SHINOBI_KEYBOARD_SYSTEM_FILE="$sysfile" \
  HYPRLAND_INSTANCE_SIGNATURE=x sh "$HELPER" apply >"$work/out" 2>"$work/err" || rc=$?
check "in a session with no hyprctl: it fails, and says that" \
  "$rc|$(grep -c 'hyprctl not found' "$work/err" || true)" "1|1"
fresh
printf '%s' "$calamares_de" >"$sysfile"
helper apply
check "outside a Hyprland session it only writes the file" "$rc|$(count hyprctl)|$(applied)" "0|0|de|||pc105"
check "and leaves no temporary files behind" "$(ls -A "$home/.config/hypr")" "input.conf"
helper set --layout de
check "nor in the runtime directory" "$(ls -A "$run/shinobi")" "keyboard"

section "the variant Calamares drops from the files is put back"
# Real xkbcommon, because "this variant is wrong" is the claim.
if [[ $have_xkb == yes ]]; then
  broken_rc=0
  xkb type privet us,ru phonetic >/dev/null 2>&1 || broken_rc=$?
  check "the files for Russian (phonetic), as Calamares writes them, are not a keymap xkb compiles" "$broken_rc" "1"
fi
fresh
python3 -I "$CALAMARES" default ru phonetic >"$sysfile"
python3 -I "$CALAMARES" x11 ru phonetic >"$x11file"
check "the transcription writes it short by one entry, as the real one does" \
  "$(grep -c '^XKBVARIANT="phonetic"$' "$sysfile")|$(grep -c 'XkbVariant" "phonetic"' "$x11file")" "1|1"
helper repair
check "repair pads both files" \
  "$(grep -c '^XKBVARIANT=",phonetic"$' "$sysfile")|$(grep -c 'XkbVariant" ",phonetic"' "$x11file")" "1|1"
check "and says so" "$(grep -c 'phonetic' <<<"$err" || true)" "1"
check "nothing else in them moved" \
  "$(grep -c -E '^XKBLAYOUT="us,ru"$|^XKBOPTIONS="grp:alt_shift_toggle"$|^XKBMODEL="pc105"$' "$sysfile")|$(grep -c 'XkbLayout" "us,ru"' "$x11file")" "3|1"
if [[ $have_xkb == yes ]]; then
  fixed_rc=0
  xkb type privet us,ru ,phonetic >/dev/null 2>&1 || fixed_rc=$?
  check "the padded form is a keymap xkb compiles" "$fixed_rc" "0"
fi
helper repair
check "repairing again changes nothing, and is silent" \
  "$(grep -c '^XKBVARIANT=",phonetic"$' "$sysfile")|$err" "1|"
helper apply
check "and the session gets the layout that was chosen" "$(applied)" "us,ru|,phonetic|grp:alt_shift_toggle|pc105"
fresh
printf '%s' "$calamares_de" >"$sysfile"
cp "$sysfile" "$work/de.before"
helper repair
check "a system with one layout is left alone" "$(cmp -s "$work/de.before" "$sysfile" && echo same || echo changed)|$err" "same|"
fresh
printf 'XKBLAYOUT="us,ru"\nXKBVARIANT="$(touch x)"\n' >"$sysfile"
cp "$sysfile" "$work/hostile.before"
helper repair
check "a variant that is not an xkb name is not written anywhere" \
  "$(cmp -s "$work/hostile.before" "$sysfile" && echo same || echo changed)" "same"
fresh
helper repair
check "with no keyboard file there is nothing to repair, and nothing fails" "$rc" "0"

section "the wizard's setxkbmap carries the chosen layout to the session"
# Laid out as the packages put it on a disk, so the shim finds the helper where it will be.
stage="$work/stage"
shims="$stage/usr/lib/shinobi/installer-shims"
mkdir -p "$shims"
cp "$HELPER" "$stage/usr/lib/shinobi/shinobi-keyboard"
cp "$SHIM" "$shims/setxkbmap"
chmod +x "$stage/usr/lib/shinobi/shinobi-keyboard" "$shims/setxkbmap"
cat >"$fake/setxkbmap" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG/setxkbmap"
EOF
chmod +x "$fake/setxkbmap"

# shim <args>: setxkbmap as Calamares runs it, with the shim first on PATH.
shim() {
  rc=0
  env -i PATH="$shims:$fake:$tools" HOME="$home" XDG_RUNTIME_DIR="$run" FAKE_LOG="$log" FAKE_HOME="$home" \
    SHINOBI_KEYBOARD_SYSTEM_FILE="$sysfile" ${HIS:+HYPRLAND_INSTANCE_SIGNATURE=test-instance} \
    setxkbmap "$@" >"$work/out" 2>"$work/err" || rc=$?
  out="$(<"$work/out")"
  err="$(<"$work/err")"
}
# The argument shapes are the ones Config.cpp builds (tests/calamares-keyboard.py argv).
fresh
HIS=1 shim -model pc105 -layout de
check "a single layout (-model pc105 -layout de): the session is given de" "$(applied)" "de|||pc105"
check "and Hyprland was reloaded" "$(cat "$log/hyprctl")" "reload"
check "and the real setxkbmap still ran, with exactly those arguments" "$(cat "$log/setxkbmap")" "-model pc105 -layout de"
rm -f "$log/setxkbmap"
shim -model pc105 -layout fr -variant azerty
check "with a variant (-variant azerty)" "$(applied)" "fr|azerty||pc105"
shim -model pc105 -layout de
check "and the next call, which has no -variant, clears it" "$(applied)" "de|||pc105"
rm -f "$log/setxkbmap"
shim -model pc105 -layout us,ru -variant , -option grp:alt_shift_toggle
check "a layout with us in front, as Calamares builds it (-variant ,)" \
  "$(applied)" "us,ru|,|grp:alt_shift_toggle|pc105"
check "the real setxkbmap got the bare comma too" "$(cat "$log/setxkbmap")" \
  "-model pc105 -layout us,ru -variant , -option grp:alt_shift_toggle"
shim -model pc105 -layout us,ru -variant ,phonetic -option grp:alt_shift_toggle
check "a variant on the second layout lines up (,phonetic)" \
  "$(applied)" "us,ru|,phonetic|grp:alt_shift_toggle|pc105"
shim -model pc105 -layout gb
rm -f "$log/setxkbmap"
shim -query
check "-query goes to the real one untouched, and records nothing" "$(cat "$log/setxkbmap")|$(applied)" "-query|gb|||pc105"
shim -print
check "so does -print" "$(tail -1 "$log/setxkbmap")|$(applied)" "-print|gb|||pc105"
shim -layout it -rules evdev
check "arguments it does not know are only passed on" "$(tail -1 "$log/setxkbmap")|$(applied)" "-layout it -rules evdev|gb|||pc105"
shim -model
check "a dangling option is only passed on" "$(tail -1 "$log/setxkbmap")|$(applied)" "-model|gb|||pc105"
rm -f "$log/setxkbmap" "$payload"
(cd "$work" && shim -model pc105 -layout "de;touch $payload")
check "a layout that is not an xkb name: nothing recorded, nothing run" \
  "$(applied)|$([[ -e $payload ]] && echo ran || echo none)" "gb|||pc105|none"
check "the real one still gets it as the one unparsed argument it was" "$(cat "$log/setxkbmap")" \
  "-model pc105 -layout de;touch $payload"
check "and a refusal by the helper is not a failure of the wizard's call" "$rc" "0"

rm -f "$fake/setxkbmap"
shim -model pc105 -layout es
check "no real setxkbmap installed: the session still follows, and the call succeeds" "$rc|$(applied)" "0|es|||pc105"
check "and the shim does not run itself instead" "$err" ""
mv "$stage/usr/lib/shinobi/shinobi-keyboard" "$work/helper.away"
shim -model pc105 -layout it
check "no helper (a wizard installed without the desktop): the call succeeds, and records nothing" \
  "$rc|$(applied)" "0|es|||pc105"
mv "$work/helper.away" "$stage/usr/lib/shinobi/shinobi-keyboard"

section "as root, it acts as the account that owns the session"
# The wizard runs as root. What it changes must belong to the session's account, not be a
# root-owned file in the operator's runtime directory or home.
cat >"$fake/setpriv" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG/setpriv"
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
cat >"$fake/getent" <<'EOF'
#!/bin/sh
echo "operator:x:$(id -u operator 2>/dev/null || echo 0):0:Operator:$FAKE_HOME:/bin/sh"
EOF
cat >"$fake/id" <<EOF
#!/bin/sh
if [ "\$*" = "-u" ]; then echo 0; else exec $real_id "\$@"; fi
EOF
cat >"$fake/setxkbmap" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG/setxkbmap"
EOF
chmod +x "$fake/setpriv" "$fake/getent" "$fake/id" "$fake/setxkbmap"
fresh
HIS=1 shim -model pc105 -layout de
check "it drops to the owner of XDG_RUNTIME_DIR before touching anything" \
  "$(sed -n 's/^--reuid=\([0-9]*\) .*/\1/p' "$log/setpriv")" "$($real_id -u)"
check "taking that account's groups" "$(grep -c -- '--init-groups' "$log/setpriv" || true)" "1"
check "and runs the helper as it, with the choice" \
  "$(grep -c 'shinobi-keyboard set --model pc105 --layout de --variant  --options $' "$log/setpriv" || true)" "1"
check "the session is given the layout" "$(applied)" "de|||pc105"
check "and the real setxkbmap still ran, as root" "$(cat "$log/setxkbmap")" "-model pc105 -layout de"
rm -rf "$run" "$log/setpriv"
shim -model pc105 -layout fr
check "with no runtime directory there is no session to change, and nothing is run as anyone" \
  "$rc|$(count setpriv)" "0|0"
rm -f "$fake/setpriv"
fresh
shim -model pc105 -layout fr
check "with no setpriv it does not run the helper as root instead" \
  "$(applied)|$(grep -c 'setpriv is not installed' "$work/err" || true)" "(none)|1"
rm -f "$fake/id" "$fake/getent"

section "it is on the wizard's PATH, and only the wizard's"
check "the launcher puts installer-shims first, ahead of a fixed system PATH" \
  "$(grep -c '^wizard_path="\$self/installer-shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"$' "$LAUNCHER")" "1"
check "and does not inherit the session's PATH into a root process" \
  "$(grep -c '^wizard_path=.*\$PATH' "$LAUNCHER" || true)" "0"
check "both ways of becoming root that can set it do (the polkit one cannot, and says so)" \
  "$(grep -c 'env "PATH=\$wizard_path" calamares' "$LAUNCHER")" "2"
check "the desktop entry for the wizard goes through the launcher" \
  "$(grep -c '^Exec=/usr/lib/shinobi/shinobi-installer-run$' "$ROOT/packaging/shinobi-installer/usr/share/applications/shinobi-installer.desktop")" "1"
check "the shim and the helper are executable" "$([[ -x $SHIM && -x $HELPER ]] && echo yes || echo no)" "yes"

section "the session and the lock screen are told to follow it"
hypr="$DOTFILES/hyprland.conf"
check "hyprland.conf no longer sets a layout of its own" \
  "$(grep -c -E '^[[:space:]]*kb_(layout|variant|options|model)[[:space:]]*=' "$hypr" || true)" "0"
src_line="$(grep -n '^source = ~/.config/hypr/input.conf$' "$hypr" | cut -d: -f1)"
input_line="$(grep -n '^input {' "$hypr" | cut -d: -f1)"
check "it sources input.conf before its own input block, so a layout set there wins" \
  "$([[ -n $src_line && -n $input_line && $src_line -lt $input_line ]] && echo yes || echo no)" "yes"
check "it runs shinobi-keyboard at login, by absolute path" \
  "$(grep -c '^exec-once = /usr/lib/shinobi/shinobi-keyboard apply$' "$hypr")" "1"
check "and does not use exec =, which would run again on every reload and so on its own reload" \
  "$(grep -c -E '^exec[[:space:]]*=' "$hypr" || true)" "0"
check "the lock screen sets no layout: it has the compositor's, which is the same file" \
  "$(grep -c -E 'kb_|layout' "$DOTFILES/hyprlock.conf" || true)" "0"
check "the wizard's keyboard job writes /etc/default/keyboard, which the session reads" \
  "$(grep -c '^writeEtcDefaultKeyboard: true$' "$CONF/modules/keyboard.conf")" "1"
check "keyboard.conf has none of the keys Calamares never reads (they made the page look short)" \
  "$(grep -c -E '^(keyboardLayout|keyboardModel|keyboardVariant|keyboardAdditional[A-Za-z]*|layouts):' "$CONF/modules/keyboard.conf" || true)" "0"
check "the installer repairs the files it wrote" \
  "$(grep -c 'shinobi-keyboard repair' "$ROOT/packaging/shinobi-installer/usr/lib/shinobi/shinobi-install-finalise")" "1"

section "the same key presses read the same way: a password, end to end"
if [[ $have_xkb != yes ]]; then
  printf '  FAIL the real xkb library is needed for these checks and is not usable: %s\n' "$xkb_problem"
  printf '       (install libxkbcommon0 and xkb-data)\n'
  failures=$((failures + 1))
  checks=$((checks + 1))
else
  # The three places a layout is read, for one choice of layout on the wizard's page:
  #   live      what the wizard gives the live session as the choice is made;
  #   login     what the login screen reads (the X11 file the wizard wrote);
  #   session   what Hyprland, and so the lock screen, is given from /etc/default/keyboard
  #             after the installer has repaired the files.
  # The operator types the password on `live`; `login` and `session` must read the same
  # key presses as the same password. Before this was fixed the live session and the session
  # were `us`, and that is checked too, because it is what makes the premise true.
  chosen() {
    local name="$1" layout="$2" variant="$3" password="$4" d
    d="$work/sel-$name"
    mkdir -p "$d"
    python3 -I "$CALAMARES" default "$layout" "$variant" >"$d/default"
    python3 -I "$CALAMARES" x11 "$layout" "$variant" >"$d/x11"
    local login_layout login_variant login_options
    login_layout="$(sed -n 's/.*"XkbLayout" "\(.*\)"/\1/p' "$d/x11")"
    login_variant="$(sed -n 's/.*"XkbVariant" "\(.*\)"/\1/p' "$d/x11")"
    login_options="$(sed -n 's/.*"XkbOptions" "\(.*\)"/\1/p' "$d/x11")"

    fresh
    cp "$d/default" "$sysfile"
    cp "$d/x11" "$x11file"
    helper repair
    cp "$x11file" "$d/x11.repaired"
    helper show
    local session_layout session_variant session_options session_model
    session_layout="$(field XKBLAYOUT)" session_variant="$(field XKBVARIANT)"
    session_options="$(field XKBOPTIONS)" session_model="$(field XKBMODEL)"
    login_variant="$(sed -n 's/.*"XkbVariant" "\(.*\)"/\1/p' "$d/x11.repaired")"

    fresh
    local -a args
    mapfile -t args < <(python3 -I "$CALAMARES" argv "$layout" "$variant")
    shim "${args[@]}"
    helper show
    local live_layout live_variant live_options
    live_layout="$(field XKBLAYOUT)" live_variant="$(field XKBVARIANT)" live_options="$(field XKBOPTIONS)"

    local want_variant="" want_options="" i
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ ${args[i]} == -variant ]] && want_variant="${args[i + 1]}"
      [[ ${args[i]} == -option ]] && want_options="${args[i + 1]}"
    done
    check "$name: the live session is given what the wizard chose" \
      "$live_layout|$live_variant|$live_options" "$login_layout|$want_variant|$want_options"
    # A list of only commas ("," for two layouts) and an empty one both mean "no variants".
    check "$name: the login screen is given the same layout, variant and options" \
      "$login_layout|${login_variant//,/}|$login_options" "$live_layout|${live_variant//,/}|$live_options"

    local keys before
    keys="$(xkb type "$password" "$live_layout" "$live_variant" "$live_options" pc105)"
    check "$name: the login screen reads the key presses typed in the wizard as that password" \
      "$(xkb decode "$keys" "$login_layout" "$login_variant" "$login_options")" "$password"
    check "$name: the session does, and so the lock screen" \
      "$(xkb decode "$keys" "$session_layout" "$session_variant" "$session_options" "$session_model")" "$password"
    before="$(xkb decode "$keys" us)"
    if [[ $layout == ru || $layout == ua ]]; then
      check "$name: an ASCII password is the same on plain us, since us comes first" "$before" "$password"
    else
      check "$name: on the old us session the same key presses are a different password" \
        "$([[ $before != "$password" ]] && echo different || echo same)" "different"
    fi
  }

  # Passwords with letters, digits and punctuation the layouts disagree about. (For a layout
  # that has no ASCII Calamares puts us first, and an ASCII password does not change.)
  chosen gb gb "" 'pa"ss@w0rd#~Ab'
  chosen de de "" 'Zy7-qQ9;yZ/Ab'
  chosen de-nodeadkeys de nodeadkeys 'zy7Q9y/Z'
  chosen fr fr azerty 'azerty19@Qa'
  chosen fr-default fr "" 'wazqs1&2;m'
  chosen es es "" "pa'ss;w0rd-Ab"
  chosen it it "" 'pa"ss;w0rd/Ab'
  chosen pt pt "" 'pa"ss;w0rd-Ab'
  chosen nl nl "" 'pa"ss;w0rd-Ab'
  chosen se se "" 'pa"ss;w0rd/Ab'
  chosen ru ru "" 'passw0rd-Ab'
  chosen ua ua "" 'passw0rd-Ab'
  chosen ru-phonetic ru phonetic 'passw0rd-Ab'

  # Cyrillic, typed after Alt+Shift, is read the same way by the login screen as by the live
  # session -- possible only once the variant is where it belongs.
  cyr="$(xkb type 'привет' us,ru ,phonetic grp:alt_shift_toggle pc105 1)"
  check "ru-phonetic: Cyrillic typed on the live session is read as Cyrillic by the login screen" \
    "$(xkb decode "$cyr" us,ru ,phonetic grp:alt_shift_toggle pc105 1)" "привет"
fi

printf '\n'
if ((failures > 0)); then
  printf 'keyboard-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nkeyboard-test: PASS\n' "$checks" "$checks"
