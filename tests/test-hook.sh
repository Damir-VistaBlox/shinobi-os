#!/usr/bin/env bash
# Tests for shinobi-hook.
#
# Three problems this covers:
#   1. `install` never validated the event name, which becomes a path component,
#      so `hook install ../../cron.d/x ./payload` wrote an executable outside the
#      hooks tree.
#   2. `run` executed anything executable in the hooks directory with no
#      confirmation, so an installed hook was a persistence mechanism.
#   3. A hooks root that any local user can write is remote code execution for
#      the next `hook run`, because run executes whatever it finds there.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# Nested one level deeper so a "../../" traversal lands inside the temp dir
# rather than in /tmp: demonstrating the write is enough, and the test should not
# leave a directory behind in the real filesystem when it runs against a
# vulnerable version.
export SHINOBI_SYSTEM_HOOKS="$work/tree/system"
export SHINOBI_USER_HOOKS="$work/tree/user"
mkdir -p "$SHINOBI_SYSTEM_HOOKS" "$SHINOBI_USER_HOOKS"

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

hook() { "$ROOT/bin/shinobi-hook" "$@"; }

cat > "$work/good.sh" <<'EOF'
#!/usr/bin/env bash
echo "good hook ran"
EOF
cat > "$work/records.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$HOOK_RECORD"
EOF
cat > "$work/bad.sh" <<'EOF'
#!/usr/bin/env bash
if then
EOF
printf 'not a script at all\n' > "$work/noshebang.sh"

echo "== install refuses to write outside the hooks tree =="
for evil in "../../cron.d/x" "../escape" "a/b" "/absolute" "UPPER" "with space" ".hidden" ".."; do
  if hook install "$evil" "$work/good.sh" >/dev/null 2>&1; then
    check "install refuses event '$evil'" "accepted" "refused"
  else
    check "install refuses event '$evil'" "refused" "refused"
  fi
done
check "nothing escaped the hooks tree" \
  "$([[ -e "$work/tree/escape" || -e "$work/escape" ]] && echo escaped || echo contained)" "contained"
check "no cron.d was created outside the hooks tree" \
  "$([[ -e "$work/cron.d" || -e "$work/tree/cron.d" ]] && echo created || echo absent)" "absent"

echo "== install accepts a well-formed event and refuses bad scripts =="
check "a valid event installs" "$(hook install post-boot "$work/good.sh" >/dev/null 2>&1; echo $?)" "0"
check "the hook is where it should be" "$([[ -x "$SHINOBI_USER_HOOKS/post-boot/good.sh" ]] && echo yes || echo no)" "yes"
check "a script with a syntax error is refused" "$(hook install post-boot "$work/bad.sh" >/dev/null 2>&1; echo $?)" "1"
check "the bad script was not installed" "$([[ -e "$SHINOBI_USER_HOOKS/post-boot/bad.sh" ]] && echo yes || echo no)" "no"
check "a file with no shebang is refused" "$(hook install post-boot "$work/noshebang.sh" >/dev/null 2>&1; echo $?)" "1"
ln -sf "$work/good.sh" "$work/link.sh"
check "a symlinked source is refused" "$(hook install post-boot "$work/link.sh" >/dev/null 2>&1; echo $?)" "1"

echo "== a hooks root anyone can write is refused =="
chmod 0777 "$SHINOBI_USER_HOOKS"
export HOOK_RECORD="$work/record.txt"
mkdir -p "$SHINOBI_USER_HOOKS/post-boot"
install -m 0755 "$work/records.sh" "$SHINOBI_USER_HOOKS/post-boot/records"
check "a world-writable user root is reported" \
  "$(hook run post-boot --yes 2>&1 | grep -c 'group/world-writable' | tr -d ' ')" "1"
check "a world-writable user root runs nothing" \
  "$(hook run post-boot --yes >/dev/null 2>&1; echo $?)" "1"
check "the planted hook never executed" "$([[ -e "$HOOK_RECORD" ]] && echo ran || echo not-run)" "not-run"
chmod 0755 "$SHINOBI_USER_HOOKS"
check "an owner-only root is accepted" "$(hook run post-boot --yes >/dev/null 2>&1; echo $?)" "0"
check "the hook executed once confirmed" "$(cat "$HOOK_RECORD" 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "== a symlinked hooks root is refused =="
mv "$SHINOBI_USER_HOOKS" "$work/user-real"
ln -s "$work/user-real" "$SHINOBI_USER_HOOKS"
check "a symlinked root is refused" \
  "$(hook run post-boot --yes 2>&1 | grep -c 'is a symlink' | tr -d ' ')" "1"
check "a symlinked root runs nothing" "$(hook run post-boot --yes >/dev/null 2>&1; echo $?)" "1"
rm "$SHINOBI_USER_HOOKS"
mv "$work/user-real" "$SHINOBI_USER_HOOKS"
check "a real root works again" "$(hook run post-boot --yes >/dev/null 2>&1; echo $?)" "0"

echo "== run validates the event name too =="
for evil in "../../etc" "a/b" "UPPER" ""; do
  check "run refuses event '$evil'" "$(hook run "$evil" --yes >/dev/null 2>&1; echo $?)" "2"
done

echo "== a system hook is not gated on confirmation =="
# The live image and scripts run hooks with no terminal; a root-owned hook under
# /etc is trusted, so gating it would break the ISO for no security gain.
# The user hooks are moved aside so this measures the system root alone.
export SYSTEM_RECORD="$work/system-record.txt"
cat > "$work/system-records.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "\$SYSTEM_RECORD"
EOF
mv "$SHINOBI_USER_HOOKS/post-boot" "$work/user-post-boot-aside"
mkdir -p "$SHINOBI_SYSTEM_HOOKS/post-boot"
install -m 0755 "$work/system-records.sh" "$SHINOBI_SYSTEM_HOOKS/post-boot/records"
check "a system hook runs with no terminal and no --yes" "$(hook run post-boot < /dev/null >/dev/null 2>&1; echo $?)" "0"
check "the system hook executed" "$(cat "$SYSTEM_RECORD" 2>/dev/null | wc -l | tr -d ' ')" "1"
check "and no refusal was reported" \
  "$(hook run post-boot < /dev/null 2>&1 | grep -c 'refusing' | tr -d ' ')" "0"

echo "== an unconfirmed user hook is refused when there is no terminal =="
rm -rf "$SHINOBI_USER_HOOKS/post-boot"
mv "$work/user-post-boot-aside" "$SHINOBI_USER_HOOKS/post-boot"
rm -f "$SHINOBI_SYSTEM_HOOKS/post-boot/records"
rm -f "$HOOK_RECORD"
check "no terminal and no --yes refuses every user hook" \
  "$(hook run post-boot < /dev/null 2>&1 | grep -c 'refusing to run user hook' | tr -d ' ')" "2"
check "and exits non-zero, because a hook did not run" "$(hook run post-boot < /dev/null >/dev/null 2>&1; echo $?)" "1"
check "and says how many were skipped" \
  "$(hook run post-boot < /dev/null 2>&1 | grep -c 'skipped 2 without confirmation' | tr -d ' ')" "1"
check "the user hook did not execute" "$([[ -e "$HOOK_RECORD" ]] && echo ran || echo not-run)" "not-run"
check "--yes runs it" "$(hook run post-boot --yes >/dev/null 2>&1; echo $?)" "0"
rm -f "$HOOK_RECORD"
check "SHINOBI_HOOK_ASSUME_YES=1 runs it too" \
  "$(SHINOBI_HOOK_ASSUME_YES=1 hook run post-boot </dev/null >/dev/null 2>&1; echo $?)" "0"
check "and it executed" "$([[ -e "$HOOK_RECORD" ]] && echo ran || echo not-run)" "ran"

echo "== a failing hook is still reported =="
cat > "$work/fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
rm -f "$SHINOBI_USER_HOOKS/post-boot/records" "$SHINOBI_SYSTEM_HOOKS/post-boot/records"
install -m 0755 "$work/fail.sh" "$SHINOBI_SYSTEM_HOOKS/post-boot/fail"
check "a failing system hook fails the run" "$(hook run post-boot --yes >/dev/null 2>&1; echo $?)" "1"
check "and says which hook failed" \
  "$(hook run post-boot --yes 2>&1 | grep -c 'hook failed' | tr -d ' ')" "1"

echo "== validate checks what actually runs =="
rm -f "$SHINOBI_SYSTEM_HOOKS/post-boot/fail"
install -m 0755 "$work/good.sh" "$SHINOBI_SYSTEM_HOOKS/post-boot/good"
install -m 0755 "$work/bad.sh" "$SHINOBI_SYSTEM_HOOKS/post-boot/bad"
check "validate fails on a broken hook" "$(hook validate >/dev/null 2>&1; echo $?)" "1"
check "and names it" "$(hook validate 2>&1 | grep -c 'invalid hook' | tr -d ' ')" "1"
rm -f "$SHINOBI_SYSTEM_HOOKS/post-boot/bad"
check "validate passes once it is removed" "$(hook validate >/dev/null 2>&1; echo $?)" "0"
check "validate counts what it checked" "$(hook validate 2>&1 | grep -c 'hook(s)' | tr -d ' ')" "1"

# An extensionless executable is what run actually executes, so validate must
# check it too; it used to only look at *.sh.
install -m 0755 "$work/records.sh" "$SHINOBI_SYSTEM_HOOKS/post-boot/no-extension"
cat > "$SHINOBI_SYSTEM_HOOKS/post-boot/no-extension" <<'EOF'
#!/usr/bin/env bash
if then
EOF
chmod 0755 "$SHINOBI_SYSTEM_HOOKS/post-boot/no-extension"
check "validate catches an extensionless broken hook" "$(hook validate >/dev/null 2>&1; echo $?)" "1"
rm -f "$SHINOBI_SYSTEM_HOOKS/post-boot/no-extension"

# A deep tree must not send validate into unbounded recursion.
mkdir -p "$SHINOBI_SYSTEM_HOOKS/post-boot/a/b/c/d/e"
install -m 0755 "$work/bad.sh" "$SHINOBI_SYSTEM_HOOKS/post-boot/a/b/c/d/e/bad"
check "validate ignores hooks below the event directory" "$(hook validate >/dev/null 2>&1; echo $?)" "0"
check "and run does not execute them either" \
  "$(HOOK_RECORD="$work/should-not-exist" hook run post-boot --yes >/dev/null 2>&1; [[ -e "$work/should-not-exist" ]] && echo ran || echo not-run)" "not-run"

echo "== a symlink loop does not hang validate =="
ln -sfn "$SHINOBI_SYSTEM_HOOKS/loop" "$SHINOBI_SYSTEM_HOOKS/loop"
check "validate survives a symlink loop" \
  "$(timeout 20 "$ROOT/bin/shinobi-hook" validate >/dev/null 2>&1; echo $?)" "0"
rm -f "$SHINOBI_SYSTEM_HOOKS/loop"

echo "== list and help still work =="
check "list succeeds" "$(hook list >/dev/null 2>&1; echo $?)" "0"
check "list shows the hook from both roots" "$(hook list | grep -c 'post-boot/good' | tr -d ' ')" "2"
check "help succeeds" "$(hook --help >/dev/null 2>&1; echo $?)" "0"
check "an unknown action is rejected" "$(hook frobnicate >/dev/null 2>&1; echo $?)" "2"

echo
if (( failures > 0 )); then
  printf 'hook-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nhook-test: PASS\n' "$checks" "$checks"
