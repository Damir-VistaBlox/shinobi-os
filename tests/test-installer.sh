#!/usr/bin/env bash
# Tests for the Shinobi Installation Wizard's configuration.
#
# Two halves, and the second half is the point.
#
# The static checks are about properties that can be read off a file: the
# sequence names modules that exist, the branding is ours, the copy excludes the
# live session's state.
#
# The second half boots the actual Calamares binary against this configuration
# in a container and asserts what it says. That is not decoration: an earlier
# version of this configuration produced two shellprocess jobs with *no script*,
# because Calamares was reading both from `shellprocess.conf`, and it reported
# the welcome screen's QML as broken -- and every one of those was visible only
# in Calamares' own output. A wizard's configuration that has never been loaded
# by the wizard has not been tested.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/packaging/shinobi-installer"

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

CONF="$PKG/etc/calamares"
SETTINGS="$CONF/settings.conf"

echo "== the wizard's own self-check passes on its contents =="
if stage="$(mktemp -d)"; then
  trap 'chmod -R u+rwX "$stage" 2>/dev/null; rm -rf "$stage"' EXIT
  "$ROOT/packaging/build-deb.sh" installer --stage "$stage"
  if "$stage/usr/lib/shinobi/shinobi-installer-check" >/dev/null 2>&1; then
    check "shinobi-installer-check accepts the shipped configuration" "ok" "ok"
  else
    check "shinobi-installer-check accepts the shipped configuration" \
      "$("$stage/usr/lib/shinobi/shinobi-installer-check" 2>&1 | head -1)" "ok"
  fi

  section "the package is what it claims to be"
  for f in \
    etc/calamares/settings.conf \
    etc/calamares/branding/shinobi/branding.desc \
    etc/calamares/branding/shinobi/show.qml \
    etc/calamares/branding/shinobi/shinobi-logo.png \
    etc/calamares/branding/shinobi/stylesheet.qss \
    etc/calamares/modules/unpackfs.conf \
    "etc/calamares/modules/shellprocess@prep.conf" \
    "etc/calamares/modules/shellprocess@finish.conf" \
    usr/lib/shinobi/shinobi-installer-check \
    usr/share/applications/shinobi-installer.desktop
  do
    check "ships $f" "$([[ -s "$stage/$f" ]] && echo yes || echo no)" "yes"
  done
  check "the launcher starts the same binary the package depends on" \
    "$(grep -c '^Exec=calamares$' "$stage/usr/share/applications/shinobi-installer.desktop" || true)" "1"
  check "it is marked executable in the session" \
    "$(grep -c 'Terminal=false' "$stage/usr/share/applications/shinobi-installer.desktop" || true)" "1"
fi

section "the configuration is valid YAML"
if command -v python3 >/dev/null 2>&1; then
  yaml_result=$(python3 - "$CONF" <<'PY' 2>&1
import sys, pathlib
try:
    import yaml
except ImportError:
    print("SKIP: no pyyaml")
    sys.exit(0)
conf = pathlib.Path(sys.argv[1])
bad = []
for path in sorted(conf.rglob("*.conf")) + [conf / "settings.conf"]:
    try:
        list(yaml.safe_load_all(path.read_text()))
    except Exception as exc:
        bad.append(f"{path.name}: {exc}")
print("\n".join(bad) if bad else "ok")
PY
)
  check "every module config and settings.conf parses" "$yaml_result" "ok"
else
  echo "  SKIP (no python3)"
fi

section "the sequence is complete and ordered"
for module in welcome partition users summary finished mount unpackfs fstab machineid \
  keyboard bootloader umount services-systemd; do
  check "$module is in the sequence" \
    "$(grep -qE "^[[:space:]]*-[[:space:]]*${module}[[:space:]]*$" "$SETTINGS" && echo yes || echo no)" "yes"
done

# Order is not cosmetic. The account has to be removed before it can be created,
# and the layer applied after it exists -- both are easy to reorder while moving
# a line, and neither shows up as an error if you get it backwards.
prep_line=$(grep -nE '^[[:space:]]*-[[:space:]]*shellprocess@prep[[:space:]]*$' "$SETTINGS" | cut -d: -f1)
# `users` appears twice legitimately: once as a page, once as the job that
# creates the account. The ordering question is about the second, so take the
# last match rather than failing to parse two line numbers.
users_line=$(grep -nE '^[[:space:]]*-[[:space:]]*users[[:space:]]*$' "$SETTINGS" | cut -d: -f1 | tail -1)
finish_line=$(grep -nE '^[[:space:]]*-[[:space:]]*shellprocess@finish[[:space:]]*$' "$SETTINGS" | cut -d: -f1)
boot_line=$(grep -nE '^[[:space:]]*-[[:space:]]*bootloader[[:space:]]*$' "$SETTINGS" | cut -d: -f1)
check "the live account is removed before the new one is created" \
  "$([[ -n $prep_line && -n $users_line && $prep_line -lt $users_line ]] && echo yes || echo no)" "yes"
check "the layer is applied after the account exists" \
  "$([[ -n $users_line && -n $finish_line && $users_line -lt $finish_line ]] && echo yes || echo no)" "yes"
check "the bootloader is installed after the layer, so it cannot go stale" \
  "$([[ -n $finish_line && -n $boot_line && $finish_line -lt $boot_line ]] && echo yes || echo no)" "yes"

section "nothing is committed without the operator confirming it"
check "the install prompt is enabled" \
  "$(grep -qE '^prompt-install:[[:space:]]*true' "$SETTINGS" && echo yes || echo no)" "yes"
check "cancelling is possible before the work starts" \
  "$(grep -qE '^disable-cancel:[[:space:]]*false' "$SETTINGS" && echo yes || echo no)" "yes"
check "and the back button is hidden once it starts" \
  "$(grep -qE '^hide-back-and-next-during-exec:[[:space:]]*true' "$SETTINGS" && echo yes || echo no)" "yes"

section "the two shellprocess jobs are configured separately"
# A bare instance name means both jobs read shellprocess.conf, so the second
# would run the first's script. Calamares warns about this and carries on.
check "both jobs are declared with their own config" \
  "$(grep -cE '^[[:space:]]+config:[[:space:]]+shellprocess@' "$SETTINGS" || true)" "2"
check "the instance declarations are maps, not bare names" \
  "$(grep -cE '^[[:space:]]+- id:' "$SETTINGS" || true)" "2"
check "each config file exists" \
  "$([[ -s "$CONF/modules/shellprocess@prep.conf" && -s "$CONF/modules/shellprocess@finish.conf" ]] && echo yes || echo no)" "yes"

prep_scripts=$(grep -c -- '- command: chroot' "$CONF/modules/shellprocess@prep.conf" || true)
finish_scripts=$(grep -c -- '- command: chroot' "$CONF/modules/shellprocess@finish.conf" || true)
check "prep runs commands" "$([[ $prep_scripts -ge 1 ]] && echo yes || echo no)" "yes"
check "finish runs commands" "$([[ $finish_scripts -ge 1 ]] && echo yes || echo no)" "yes"

section "the install is offline"
# An offline install that quietly depends on a repository is an install that
# fails on a train, and it is invisible until then.
if grep -rEq '^[[:space:]]*(-[[:space:]]*)?(command:[[:space:]]*)?(apt-get|apt|curl|wget|git|pacman|dhcpcd)[[:space:]]' \
  "$CONF/modules/" 2>/dev/null; then
  check "no module config runs a network client" "found one" "none"
else
  check "no module config runs a network client" "none" "none"
fi
check "the settings do not list an internet check" \
  "$(grep -qE '^[[:space:]]*-[[:space:]]*internet[[:space:]]*$' "$CONF/modules/welcome.conf" && echo yes || echo no)" "no"
check "the wizard does not install packages from a repository at install time" \
  "$(grep -qE '^[[:space:]]*-[[:space:]]*(packages|netinstall|sources-final)[[:space:]]*$' "$SETTINGS" && echo yes || echo no)" "no"

section "the live session's state does not follow onto the disk"
unpack_sources=$(grep -cE '^[[:space:]]*-[[:space:]]+source:' "$CONF/modules/unpackfs.conf" || true)
for excluded in '/home/*' '/root/*' 'sudoers.d/live'; do
  occurrences=$(grep -cF -- "$excluded" "$CONF/modules/unpackfs.conf" || true)
  # Once per source. An exclusion on the first source only leaves the fallback
  # source -- the one that runs when the squashfs is not where we expected --
  # copying the live session's home onto the disk.
  check "every unpack source excludes $excluded" \
    "$occurrences" "$unpack_sources"
done
check "prep removes the live account" \
  "$(grep -q 'userdel' "$CONF/modules/shellprocess@prep.conf" && echo yes || echo no)" "yes"
check "prep refuses to remove an account that has a home directory" \
  "$(grep -q '\[ ! -d ' "$CONF/modules/shellprocess@prep.conf" && echo yes || echo no)" "yes"
# The executable lines only: the file explains at length why this matters, and
# grepping the whole file meant a comment could satisfy the check on its own.
finish_cmds() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$CONF/modules/shellprocess@finish.conf"; }
check "finish removes any autologin configuration" \
  "$(finish_cmds | grep -qiE 'autologin|sddm.conf.d' && echo yes || echo no)" "yes"
check "and does so for more than one display manager" \
  "$(finish_cmds | grep -qiE 'gdm3|lightdm' && echo yes || echo no)" "yes"
check "the users module does not configure autologin" \
  "$(grep -qE '^[[:space:]]*autologinGroup' "$CONF/modules/users.conf" && echo yes || echo no)" "no"

section "the wizard applies the layer rather than copying it and hoping"
check "finish calls shinobi-setup" \
  "$(grep -q 'shinobi-setup' "$CONF/modules/shellprocess@finish.conf" && echo yes || echo no)" "yes"
check "and writes provenance" \
  "$(grep -q 'shinobi-setup provenance\|provenance' "$CONF/modules/shellprocess@finish.conf" && echo yes || echo no)" "yes"
check "and checks the control plane arrived" \
  "$(grep -q 'shinobi-agent' "$CONF/modules/shellprocess@finish.conf" && echo yes || echo no)" "yes"
check "and the recon server with it" \
  "$(grep -q 'shinobi-recon' "$CONF/modules/shellprocess@finish.conf" && echo yes || echo no)" "yes"

section "nothing in the wizard presents itself as Kali"
# The base distribution's name on the screen where somebody decides what to
# install is not a cosmetic detail: it is the one place the operator can be told
# what they are getting.
for f in "$SETTINGS" "$CONF/branding/shinobi/branding.desc" "$CONF/branding/shinobi/show.qml"; do
  # The slides do mention Kali, on purpose: the wizard says the base is Kali and
  # unmodified, which is a claim the operator is entitled to. What must not
  # happen is Kali being the *name of the thing being installed*.
  if [[ $f == *branding.desc ]]; then
    hits=$(grep -cEi '(productName|shortProductName|versionedName|shortVersionedName|installationWizardName|bootloaderEntryName):[[:space:]]*"?[^"]*kali' "$f" || true)
  else
    hits=0
  fi
  check "$(basename "$f") does not name Kali as the product" "$hits" "0"
done
check "the wizard's own name is set" \
  "$(grep -q 'installationWizardName:[[:space:]]*Shinobi' "$CONF/branding/shinobi/branding.desc" && echo yes || echo no)" "yes"
check "the bootloader entry is named for Shinobi" \
  "$(grep -q 'bootloaderEntryName:[[:space:]]*Shinobi' "$CONF/branding/shinobi/branding.desc" && echo yes || echo no)" "yes"

section "the branding is complete"
# Two of these live under `strings:` and are indented; grepping for them at the
# start of a line finds nothing, which is a test that cannot fail rather than a
# test that passes.
for key in strings style images slideshow sidebar navigation; do
  check "branding.desc has $key" \
    "$(grep -q "^$key:" "$CONF/branding/shinobi/branding.desc" && echo yes || echo no)" "yes"
done
for key in productName installationWizardName bootloaderEntryName; do
  check "branding.desc names $key under strings" \
    "$(grep -qE "^[[:space:]]+$key:" "$CONF/branding/shinobi/branding.desc" && echo yes || echo no)" "yes"
done
check "the logo the branding references is shipped" \
  "$([[ -s "$CONF/branding/shinobi/shinobi-logo.png" ]] && echo yes || echo no)" "yes"
check "the slideshow has slides" \
  "$([[ $(grep -c 'ShinobiSlide {' "$CONF/branding/shinobi/show.qml" || true) -ge 5 ]] && echo yes || echo no)" "yes"
# The first version referenced a nested item's `id` from the slide instances,
# which is not valid QML; Calamares reported the welcome screen as broken.
check "the slideshow does not reference ids across component boundaries" \
  "$(grep -qE 'heading\.text|body\.text' "$CONF/branding/shinobi/show.qml" && echo yes || echo no)" "no"

section "Calamares itself accepts this configuration"
if ! command -v docker >/dev/null 2>&1; then
  echo "  SKIP (no docker; the static checks above still run)"
else
  smoke_root="$(mktemp -d)"
  if "$ROOT/packaging/build-deb.sh" installer --stage "$smoke_root" 2>/dev/null; then
    log="$(docker run --rm -v "$smoke_root:/inst:ro" kalilinux/kali-rolling:latest bash -c '
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq calamares xvfb >/dev/null 2>&1
      mkdir -p /etc/calamares && cp -r /inst/etc/calamares/. /etc/calamares/
      timeout 60 xvfb-run -a calamares -d 2>&1' 2>&1)"
    chmod -R u+rwX "$smoke_root" 2>/dev/null
    rm -rf "$smoke_root"

    check "it loads our branding" \
      "$(grep -c 'Loaded branding component "shinobi"' <<<"$log" || true)" "1"
    for module in welcome keyboard partition users summary finished; do
      check "the $module page loads" \
        "$(grep -c "ViewModule \"$module@$module\" loading complete" <<<"$log" || true)" "1"
    done

    # Each of these was a real defect in an earlier revision, and every one of
    # them is something Calamares reports without failing.
    check "no job is configured with no script" \
      "$(grep -c 'No script given' <<<"$log" || true)" "0"
    check "no module in the sequence lacks its configuration" \
      "$(grep -c 'No config file for' <<<"$log" || true)" "0"
    check "every instance key is declared" \
      "$(grep -c 'is not listed in the \*instances\*' <<<"$log" || true)" "0"
    check "no QML component failed to load" \
      "$(grep -c 'QML component not ready' <<<"$log" || true)" "0"
    check "the swap choices are understood" \
      "$(grep -c 'userSwapChoices\* is empty' <<<"$log" || true)" "0"
    check "the LUKS generation is understood" \
      "$(grep -c 'luksGeneration\* not found or invalid' <<<"$log" || true)" "0"
    check "the welcome page has an internet check URL" \
      "$(grep -c "entry 'internetCheckUrl' is undefined" <<<"$log" || true)" "0"

    # A crash would show up as none of the pages loading, which the checks above
    # already catch; this is here so a future Calamares that logs differently
    # does not pass by accident.
    check "the run produced no fatal error" \
      "$(grep -ciE 'ASSERT|FATAL' <<<"$log" || true)" "0"
  else
    check "the installer package could be staged for the smoke test" "failed" "staged"
  fi
fi

printf '\n'
if ((failures > 0)); then
  printf 'installer-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ninstaller-test: PASS\n' "$checks" "$checks"