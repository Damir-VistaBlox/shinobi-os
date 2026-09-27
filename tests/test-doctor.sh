#!/usr/bin/env bash
# Tests for `shinobi doctor security`, which asserted a security posture but
# had no coverage at all.
#
# Its Polkit check was the clearest example: it *failed* when a policy file was
# absent, and that file declared org.shinobi.* actions no code ever invoked, so
# it authorised nothing. A check that rewards keeping a useless file is worse
# than no check, because it is believed.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d)"
trap 'chmod -R u-s,g-s "$work" 2>/dev/null || true; rm -rf -- "$work"' EXIT

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

# A private state/runtime home so the checks read this test's files, not the
# developer's real ones.
export XDG_STATE_HOME="$work/state" XDG_RUNTIME_DIR="$work/runtime"
export SHINOBI_AUDIT_FILE="$work/state/shinobi/audit.jsonl"
mkdir -p "$XDG_STATE_HOME/shinobi" "$XDG_RUNTIME_DIR/shinobi" "$work/bin" "$work/lib"

run_doctor() {
  SHINOBI_DOCTOR_EXTRA_PATHS="${SHINOBI_DOCTOR_EXTRA_PATHS:-}" "$ROOT/bin/shinobi-doctor" security 2>&1
}

echo "== a clean system passes =="
check "clean run exits 0" "$(run_doctor >/dev/null 2>&1; echo $?)" "0"
check "clean run says nothing" "$(run_doctor)" ""

echo "== the agent socket must not be world- or group-accessible =="
touch "$XDG_RUNTIME_DIR/shinobi/agent.sock"
chmod 666 "$XDG_RUNTIME_DIR/shinobi/agent.sock"
check "a 0666 socket is reported" "$(run_doctor | grep -c 'agent socket must be mode 0600' | tr -d ' ')" "1"
check "a 0666 socket fails the check" "$(run_doctor >/dev/null 2>&1; echo $?)" "1"
chmod 600 "$XDG_RUNTIME_DIR/shinobi/agent.sock"
check "a 0600 socket passes" "$(run_doctor >/dev/null 2>&1; echo $?)" "0"

echo "== the audit journal must not be world- or group-accessible =="
: > "$SHINOBI_AUDIT_FILE"
chmod 644 "$SHINOBI_AUDIT_FILE"
check "a 0644 audit log is reported" "$(run_doctor | grep -c 'audit journal must be mode 0600' | tr -d ' ')" "1"
chmod 600 "$SHINOBI_AUDIT_FILE"
check "a 0600 audit log passes" "$(run_doctor >/dev/null 2>&1; echo $?)" "0"

echo "== an unrecognised trust profile is refused =="
echo "root" > "$XDG_STATE_HOME/shinobi/profile"
check "an invalid profile is reported" "$(run_doctor | grep -c 'invalid trust profile' | tr -d ' ')" "1"
for profile in observer analyst operator administrator emergency; do
  echo "$profile" > "$XDG_STATE_HOME/shinobi/profile"
  check "the $profile profile is accepted" "$(run_doctor >/dev/null 2>&1; echo $?)" "0"
done
rm -f "$XDG_STATE_HOME/shinobi/profile"
check "a missing profile defaults to observer and passes" "$(run_doctor >/dev/null 2>&1; echo $?)" "0"

echo "== a setuid shinobi binary is refused =="
cp "$ROOT/bin/shinobi-capture" "$work/bin/shinobi-probe"
chmod u+s "$work/bin/shinobi-probe"
check "a setuid shinobi binary is reported" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/bin" run_doctor | grep -c 'setuid/setgid shinobi binary' | tr -d ' ')" "1"
check "a setuid shinobi binary fails the check" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/bin" run_doctor >/dev/null 2>&1; echo $?)" "1"
chmod g+s "$work/bin/shinobi-probe"
check "a setgid shinobi binary is also caught" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/bin" run_doctor | grep -c 'setuid/setgid shinobi binary' | tr -d ' ')" "1"
chmod u-s,g-s "$work/bin/shinobi-probe"
check "the same binary without setuid/setgid passes" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/bin" run_doctor >/dev/null 2>&1; echo $?)" "0"

echo "== unrelated setuid binaries are not shinobi's business =="
cp "$ROOT/bin/shinobi-capture" "$work/bin/other-tool"
chmod u+s "$work/bin/other-tool"
check "a setuid binary not named shinobi* is ignored" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/bin" run_doctor >/dev/null 2>&1; echo $?)" "0"
chmod u-s "$work/bin/other-tool"

echo "== a non-default prefix is scanned, and a missing one is not an error =="
mkdir -p "$work/prefix/bin"
cp "$ROOT/bin/shinobi-capture" "$work/prefix/bin/shinobi-thing"
chmod u+s "$work/prefix/bin/shinobi-thing"
check "an extra path is scanned" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/prefix/bin" run_doctor | grep -c 'setuid/setgid' | tr -d ' ')" "1"
cp "$ROOT/bin/shinobi-capture" "$work/bin/shinobi-second"
chmod u+s "$work/bin/shinobi-second"
check "several colon-separated paths are all scanned" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/bin:$work/prefix/bin" run_doctor | grep -c 'setuid/setgid' | tr -d ' ')" "2"
chmod u-s "$work/bin/shinobi-second"
check "a non-existent extra path is not an error" \
  "$(SHINOBI_DOCTOR_EXTRA_PATHS="$work/nope" run_doctor >/dev/null 2>&1; echo $?)" "0"

echo "== the dead Polkit policy must not come back =="
check "the repository no longer ships it" \
  "$([[ -e "$ROOT/packaging/shinobi-core/usr/share/polkit-1/actions/org.shinobi.policy" ]] && echo present || echo absent)" "absent"
check "the doctor no longer requires it" \
  "$(run_doctor | grep -c 'Polkit action policy missing' | tr -d ' ')" "0"
check "no source file references the dead action ids" \
  "$(git -C "$ROOT" grep -l 'org\.shinobi\.package\.\|org\.shinobi\.update\.\|org\.shinobi\.snapshot\.\|org\.shinobi\.network\.' -- . 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== the packaged tree has no setuid or setgid file =="
check "nothing in bin/ or libexec/ is setuid/setgid" \
  "$(find "$ROOT/bin" "$ROOT/libexec" -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l | tr -d ' ')" "0"

echo
if (( failures > 0 )); then
  printf 'doctor-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ndoctor-test: PASS\n' "$checks" "$checks"
