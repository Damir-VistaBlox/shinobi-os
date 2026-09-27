#!/usr/bin/env bash
# Tests for the webapp wrapper.
#
# `install` validated the URL, but `launch` read `browser` and `url` back out of
# the persisted webapp.json and handed them straight to subprocess.Popen. The
# record outlives the install-time check, so anything able to edit that file --
# a restored backup, a synced directory, another tool -- picked the program that
# ran. And validate_url accepted quotes, spaces and percent signs, all of which
# are structural in a desktop entry's Exec= line, so a URL could smuggle extra
# browser flags into the generated .desktop file.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export work
export SHINOBI_WEBAPP_DIR="$work/webapps"
export XDG_DATA_HOME="$work/share"
export SHINOBI_CONFIRM=1
# A fake browser, so launching is observable and never opens a real window.
mkdir -p "$work/bin"
cat > "$work/bin/fake-browser" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$0" "\$@" > "$work/launch-args"
EOF
chmod +x "$work/bin/fake-browser"
export SHINOBI_BROWSER="$work/bin/fake-browser"

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

webapp() { python3 "$ROOT/libexec/shinobi/shinobi_control/webappctl.py" "$@"; }

echo "== install validates the URL =="
check "a plain https URL installs" "$(webapp install ok https://example.com >/dev/null 2>&1; echo $?)" "0"
check "the record is written" "$([[ -f "$SHINOBI_WEBAPP_DIR/ok/webapp.json" ]] && echo yes || echo no)" "yes"
check "the profile is private" "$(stat -c '%a' "$SHINOBI_WEBAPP_DIR/ok/profile" | tr -d ' ')" "700"
check "the record is inside a private directory" "$(stat -c '%a' "$SHINOBI_WEBAPP_DIR/ok" | tr -d ' ')" "700"

for bad in \
  'http://example.com' \
  'https://' \
  'https://user:pass@example.com' \
  'https://example.com#frag' \
  'javascript:alert(1)' \
  'file:///etc/passwd' \
  'https://example.com/a b' \
  'https://example.com/a"b' \
  "https://example.com/a'b" \
  'https://example.com/a\b' \
  'https://example.com/%u' \
  'https://example.com/100%' \
  'https://example.com/`id`' \
  'https://example.com/$(id)' \
  'https://example.com/<script>' \
  'https://example.com/a
b'
do
  check "install refuses $(printf '%q' "$bad")" "$(webapp install bad "$bad" >/dev/null 2>&1; echo $?)" "1"
done
check "nothing was installed for the rejected URLs" "$([[ -e "$SHINOBI_WEBAPP_DIR/bad" ]] && echo yes || echo no)" "no"

echo "== install requires confirmation and a valid name =="
check "install without SHINOBI_CONFIRM is refused" \
  "$(SHINOBI_CONFIRM=0 webapp install other https://example.com >/dev/null 2>&1; echo $?)" "1"
for bad_name in "../escape" "a/b" "UPPER" ".hidden" "with space" ""; do
  check "install refuses the name $(printf '%q' "$bad_name")" \
    "$(webapp install "$bad_name" https://example.com >/dev/null 2>&1; echo $?)" "1"
done
check "no directory escaped the webapps root" \
  "$([[ -e "$work/escape" ]] && echo escaped || echo contained)" "contained"

echo "== launch re-validates the record instead of trusting it =="
# The core finding: a tampered record must not choose the program that runs.
python3 - "$SHINOBI_WEBAPP_DIR/ok/webapp.json" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["url"] = "http://evil.example.com"
json.dump(record, open(path, "w"))
PY
check "a record with a non-HTTPS url is refused" "$(webapp launch ok >/dev/null 2>&1; echo $?)" "1"
check "and the browser was never started" "$([[ -e "$work/launch-args" ]] && echo ran || echo not-run)" "not-run"

python3 - "$SHINOBI_WEBAPP_DIR/ok/webapp.json" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["url"] = "https://example.com/\" --incognito"
json.dump(record, open(path, "w"))
PY
check "a record with a quote in the url is refused" "$(webapp launch ok >/dev/null 2>&1; echo $?)" "1"
check "and again the browser never started" "$([[ -e "$work/launch-args" ]] && echo ran || echo not-run)" "not-run"

# A sentinel that records being executed. Pointing the record at /bin/sh proved
# nothing: it failed silently, so "ignored" and "not obeyed" both passed by
# accident against the vulnerable version.
cat > "$work/bin/sentinel" <<'SENTINEL'
#!/usr/bin/env bash
touch "$SENTINEL_MARKER"
printf '%s\n' "$0" "$@" >> "$work/sentinel-args"
SENTINEL
chmod +x "$work/bin/sentinel"
export SENTINEL_MARKER="$work/SENTINEL"
python3 - "$SHINOBI_WEBAPP_DIR/ok/webapp.json" <<'PY'
import json, os, sys
path = sys.argv[1]
record = json.load(open(path))
record["browser"] = os.environ["work"] + "/bin/sentinel"
record["url"] = "https://example.com"
json.dump(record, open(path, "w"))
PY
check "launching a webapp with a tampered browser path still succeeds" \
  "$(webapp launch ok >/dev/null 2>&1; echo $?)" "0"
check "the browser named in the record was NOT executed" \
  "$([[ -e "$work/SENTINEL" ]] && echo executed || echo ignored)" "ignored"
check "the resolved browser was launched instead" \
  "$(head -1 "$work/launch-args" 2>/dev/null | grep -q 'fake-browser' && echo yes || echo no)" "yes"
check "the launch arguments are the real browser's" \
  "$(sed -n '2p' "$work/launch-args" | grep -q -- '--user-data-dir=' && echo yes || echo no)" "yes"

echo "== launch derives the profile from the record's location =="
python3 - "$SHINOBI_WEBAPP_DIR/ok/webapp.json" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["profile"] = "/tmp/somewhere-else"
json.dump(record, open(path, "w"))
PY
rm -f "$work/launch-args"
webapp launch ok >/dev/null 2>&1
check "a tampered profile path is not used" \
  "$(grep -c 'somewhere-else' "$work/launch-args" 2>/dev/null; true)" "0"
check "the real profile directory is used instead" \
  "$(grep -q -- "--user-data-dir=$SHINOBI_WEBAPP_DIR/ok/profile" "$work/launch-args" && echo yes || echo no)" "yes"

echo "== a record whose name disagrees with its directory is refused =="
cp -r "$SHINOBI_WEBAPP_DIR/ok" "$SHINOBI_WEBAPP_DIR/copy"
python3 - "$SHINOBI_WEBAPP_DIR/copy/webapp.json" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["name"] = "ok"
json.dump(record, open(path, "w"))
PY
check "a mismatched record name is refused" "$(webapp launch copy >/dev/null 2>&1; echo $?)" "1"

echo "== a missing profile is refused rather than silently recreated =="
rm -rf "$SHINOBI_WEBAPP_DIR/copy/profile"
check "a missing profile fails the launch" "$(webapp launch copy >/dev/null 2>&1; echo $?)" "1"

echo "== a malformed record does not crash list or launch =="
mkdir -p "$SHINOBI_WEBAPP_DIR/broken"
printf 'not json at all' > "$SHINOBI_WEBAPP_DIR/broken/webapp.json"
check "list survives a malformed record" "$(webapp list >/dev/null 2>&1; echo $?)" "0"
check "and reports it" "$(webapp list | grep -c '"error"' | tr -d ' ')" "1"
check "launch on a malformed record fails cleanly" "$(webapp launch broken >/dev/null 2>&1; echo $?)" "1"
rm -rf "$SHINOBI_WEBAPP_DIR/broken"
check "launch on a missing webapp fails cleanly" "$(webapp launch nope >/dev/null 2>&1; echo $?)" "1"

echo "== the generated .desktop file cannot smuggle browser flags =="
webapp install quoted "https://example.com" >/dev/null
desktop="$XDG_DATA_HOME/applications/shinobi-webapp-quoted.desktop"
check "the desktop file exists" "$([[ -f "$desktop" ]] && echo yes || echo no)" "yes"
exec_line="$(grep '^Exec=' "$desktop")"
check "the url is quoted" "$(grep -q 'https://example.com"' <<<"$exec_line" && echo yes || echo no)" "yes"
check "the browser is quoted" "$(grep -q 'Exec="' <<<"$exec_line" && echo yes || echo no)" "yes"

# The escaping itself, exercised directly on hostile input. Missing on a
# vulnerable build, so report rather than abort.
esc_arg() {
  python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
try:
    from shinobi_control.webappctl import desktop_exec_arg
except ImportError:
    print("MISSING"); raise SystemExit(0)
print(desktop_exec_arg(sys.argv[2]))
' "$ROOT/libexec/shinobi" "$1" 2>/dev/null || echo MISSING
}
check "a quote inside an argument is escaped" \
  "$(grep -q 'a\\"b' <<<"$(esc_arg 'https://e.com/a"b')" && echo yes || echo no)" "yes"
check "a percent becomes a literal field code" \
  "$([[ "$(esc_arg '100%')" == '"100%%"' ]] && echo yes || echo no)" "yes"
check "a space is contained by quoting" \
  "$([[ "$(esc_arg 'a b')" == '"a b"' ]] && echo yes || echo no)" "yes"

echo "== remove needs confirmation and cleans up =="
check "remove without confirmation is refused" \
  "$(SHINOBI_CONFIRM=0 webapp remove quoted >/dev/null 2>&1; echo $?)" "1"
check "the webapp itself survives" "$([[ -d "$SHINOBI_WEBAPP_DIR/quoted" ]] && echo yes || echo no)" "yes"
check "remove with confirmation works" "$(webapp remove quoted >/dev/null 2>&1; echo $?)" "0"
check "the directory is gone" "$([[ -d "$SHINOBI_WEBAPP_DIR/quoted" ]] && echo yes || echo no)" "no"
check "the desktop file is gone" "$([[ -f "$desktop" ]] && echo yes || echo no)" "no"
check "removing something absent fails cleanly" "$(webapp remove quoted >/dev/null 2>&1; echo $?)" "1"

echo
if (( failures > 0 )); then
  printf 'webapp-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nwebapp-test: PASS\n' "$checks" "$checks"
