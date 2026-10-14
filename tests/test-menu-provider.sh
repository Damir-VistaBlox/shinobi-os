#!/usr/bin/env bash
# Tests the LLM provider route of the wofi menu: `shinobi-menu provider`.
#
# The menu is a front for `shinobi provider` and decides nothing, so what is
# checked is the edge between the two. wofi hands back whatever was typed when
# nothing matches, and `shinobi provider default` takes any word that starts with
# two dashes for a flag, so typing `--clear` in the list must not clear anything,
# and an action that was not offered for a provider must not run because someone
# typed its name. The id that reaches argv has to come from the readiness report,
# never from what the picker returned. A key is typed in a terminal, never in the
# menu, and the terminal is started from an argument vector, not a string a shell
# would parse. And what the commands say (the cloud notice, a change that was
# made but not recorded, a manifest that does not parse) has to reach the
# operator, because a menu has no terminal to print it to.
#
# wofi, kitty and notify-send are fakes: wofi answers from a script and records
# the rows and prompt it was shown, kitty records its argument vector and runs
# nothing, notify-send records what it was asked to show. `shinobi-provider` is
# the real one, over a sandbox of this test's own.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
umask 022

if [[ -e /run/live/medium/live/filesystem.squashfs ]]; then
  echo "menu-provider-test: SKIP (live image: keys live in the kernel keyring, which this suite cannot sandbox)"
  exit 0
fi
command -v jq >/dev/null || { echo "menu-provider-test: SKIP (jq is not installed)"; exit 0; }

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
contains() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }

export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
  XDG_RUNTIME_DIR="$work/run" SHINOBI_SYSTEM_CONFIG="$work/etc" SHINOBI_DEFAULTS_DIR="$work/share" \
  SHINOBI_PROVIDERS_DIR="$ROOT/providers" SHINOBI_ENGAGEMENTS_DIR="$work/engagements"
unset SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR SHINOBI_STATE_FILE SHINOBI_AUDIT_FILE
mkdir -p "$HOME" "$XDG_CONFIG_HOME/shinobi" "$XDG_STATE_HOME/shinobi" "$SHINOBI_SYSTEM_CONFIG" \
  "$SHINOBI_DEFAULTS_DIR" "$SHINOBI_ENGAGEMENTS_DIR" "$XDG_RUNTIME_DIR"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

T="$work/t"       # what the fakes record, and the answers they give
FAKES="$work/fakes"
mkdir -p "$T" "$FAKES"
export FAKE_T="$T"

cat >"$FAKES/wofi" <<'EOF'
#!/usr/bin/env bash
# A fake `wofi --dmenu --prompt P -i`: records what it was shown, answers from a script.
T="${FAKE_T:?}"
prompt=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == --prompt ]] && { prompt="$2"; shift; }
  shift
done
n=$(( $(cat "$T/picker.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$T/picker.n"
cat >"$T/picker.$n.rows"
printf '%s' "$prompt" >"$T/picker.$n.prompt"
[[ -s "$T/answers" ]] || exit 1           # nothing left to say: like pressing Esc
ans="$(head -n1 "$T/answers")"
sed -i 1d "$T/answers"
case "$ans" in
  @ESC) exit 1 ;;
  @ROW:*)
    # The row whose first word is this id, as a click would return it.
    row="$(awk -v id="${ans#@ROW:}" '$1 == id { print; exit }' "$T/picker.$n.rows")"
    [[ -n "$row" ]] || exit 1
    printf '%s\n' "$row"
    ;;
  *) printf '%s\n' "$ans" ;;               # typed text, exactly as wofi would return it
esac
EOF
cat >"$FAKES/kitty" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"${FAKE_T:?}/kitty.argv"
printf '\n' >>"$FAKE_T/kitty.calls"
EOF
cat >"$FAKES/notify-send" <<'EOF'
#!/usr/bin/env bash
T="${FAKE_T:?}"
n=$(( $(cat "$T/notify.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$T/notify.n"
printf '%s\0' "$@" >"$T/notify.$n"
EOF
chmod +x "$FAKES"/*
export PATH="$FAKES:$ROOT/bin:$PATH"

audit="$XDG_STATE_HOME/shinobi/audit.jsonl"
user_default="$XDG_CONFIG_HOME/shinobi/default-provider"

# drive <route> <answer>...: run the menu with scripted answers, from a clean slate.
rc=0
drive() {
  local route="$1"
  shift
  rm -f "$T"/picker.* "$T"/notify.* "$T"/kitty.* "$T/answers"
  : >"$T/answers"
  local a
  for a in "$@"; do printf '%s\n' "$a" >>"$T/answers"; done
  rc=0
  "$ROOT/bin/shinobi-menu" "$route" >"$work/menu.out" 2>"$work/menu.err" || rc=$?
}
pickers() { cat "$T/picker.n" 2>/dev/null || echo 0; }
rows_of() { cat "$T/picker.$1.rows" 2>/dev/null || true; }
prompt_of() { cat "$T/picker.$1.prompt" 2>/dev/null || true; }
notifications() { cat "$T/notify.n" 2>/dev/null || echo 0; }
# note <n> <i>: argument i of the n-th notification (0 is the first).
note() { python3 -c 'import sys; a = open(sys.argv[1], "rb").read().split(b"\0")[:-1]; sys.stdout.write(a[int(sys.argv[2])].decode())' "$T/notify.$1" "$2"; }
all_notes() {
  local i n
  n="$(notifications)"
  for ((i = 1; i <= n; i++)); do note "$i" -1; echo; done
}
kitty_args() { tr '\0' '|' <"$T/kitty.argv" 2>/dev/null || true; }
kitty_calls() { if [[ -e "$T/kitty.calls" ]]; then wc -l <"$T/kitty.calls"; else echo 0; fi; }
acount() {
  local n
  n="$(grep -c "\"capability\": \"$1\"" "$audit" 2>/dev/null || true)"
  echo "${n:-0}"
}
current_default() { cat "$user_default" 2>/dev/null || echo "(none)"; }

BASE_SCOPE=$'window:\n  start: "2020-01-01"\n  end: "2030-01-01"\ntargets: ["127.0.0.1"]\n'
engagement() {
  mkdir -p "$SHINOBI_ENGAGEMENTS_DIR/acme"
  printf '%s' "$1" >"$SHINOBI_ENGAGEMENTS_DIR/acme/scope.yaml"
  chmod 600 "$SHINOBI_ENGAGEMENTS_DIR/acme/scope.yaml"
  printf 'acme' >"$XDG_STATE_HOME/shinobi/current-engagement"
  printf 'operator' >"$XDG_STATE_HOME/shinobi/profile"
}

echo "== the root menu offers it =="
drive root "LLM provider" "@ESC"
check "the root list has an LLM provider entry" "$(contains "$(rows_of 1)" 'LLM provider')" "yes"
check "choosing it opens the provider list" "$(contains "$(prompt_of 2)" 'LLM provider |')" "yes"
check "and Esc there ends the menu cleanly" "$rc" "0"
check "the entry is not confusable with the agent entry" "$(contains "$(rows_of 1)" 'Set default agent')" "yes"

echo "== the list =="
drive provider "@ESC"
check "every shipped provider is a row" "$(rows_of 1 | wc -l)" "$(ls "$ROOT"/providers/*.toml | wc -l)"
check "rows are in id order" "$(rows_of 1 | awk '{print $1}')" "$(ls "$ROOT"/providers/*.toml | xargs -n1 basename | sed 's/\.toml$//')"
check "the prompt says there is no default" "$(contains "$(prompt_of 1)" 'default: none')" "yes"
check "and what the engagement is" "$(contains "$(prompt_of 1)" 'no active engagement')" "yes"
check "with no engagement every row says it is blocked, and why" \
  "$(rows_of 1 | grep -vc 'blocked: no usable engagement')" "0"
check "Esc at the list changes nothing and says nothing" "$(notifications)|$rc|$(acount provider.default)" "0|0|0"

engagement "$BASE_SCOPE"
drive provider "@ESC"
check "with an engagement a local provider is ready" "$(rows_of 1 | awk '$1 == "ollama" { print $3 }')" "ready"
check "a cloud provider says what it lacks" "$(rows_of 1 | grep '^openai ' | grep -c 'blocked: engagement has not cleared cloud egress')" "1"
check "the prompt names the engagement" "$(contains "$(prompt_of 1)" 'engagement acme')" "yes"

echo "== making a local provider the default =="
drive provider "@ROW:ollama" "Make this the default"
check "the actions offered for a local, non-default provider" \
  "$(rows_of 2 | paste -sd'|')" "Make this the default|Back"
check "the default is stored" "$(current_default)" "ollama"
check "exactly one audit record" "$(acount provider.default)" "1"
check "the operator is told, with what a local default means" \
  "$(contains "$(all_notes)" 'default provider is now ollama (local)')" "yes"
check "exactly one notification" "$(notifications)" "1"
check "the notice is passed as text after --" "$(note 1 0)" "--"
drive provider "@ESC"
check "the prompt now names it" "$(contains "$(prompt_of 1)" 'default: ollama')" "yes"
check "and the row is marked" "$(rows_of 1 | grep -c '^ollama .*(default)$')" "1"
check "no other row is" "$(rows_of 1 | grep -c '(default)$')" "1"

echo "== making a cloud provider the default carries its notice =="
drive provider "@ROW:openai" "Make this the default"
check "the default is stored" "$(current_default)" "openai"
check "the cloud notice reaches the operator" "$(contains "$(all_notes)" 'prompts leave this machine')" "yes"
check "including that a default waives nothing" "$(contains "$(all_notes)" 'waives nothing')" "yes"
check "and that no key is stored yet" "$(contains "$(all_notes)" 'no API key is stored for it yet')" "yes"
check "one more audit record" "$(acount provider.default)" "2"

echo "== what is offered depends on the provider =="
drive provider "@ROW:openai" "@ESC"
check "the default, from your own setting: clear it, keys, blockers; no 'make default'" \
  "$(rows_of 2 | paste -sd'|')" "Clear my default|Store API key|Forget stored API key|Show what blocks it|Back"
drive provider "@ROW:groq" "@ESC"
check "a cloud provider that is not the default" \
  "$(rows_of 2 | paste -sd'|')" "Make this the default|Store API key|Forget stored API key|Show what blocks it|Back"
drive provider "@ROW:ollama" "@ESC"
check "a local provider takes no key, so offers none" "$(contains "$(rows_of 2)" 'API key')" "no"
check "a usable one has nothing to explain" "$(contains "$(rows_of 2)" 'Show what blocks it')" "no"
printf 'ollama\n' >"$SHINOBI_SYSTEM_CONFIG/default-provider"
rm -f "$user_default"
drive provider "@ROW:ollama" "@ESC"
check "a default that comes from the system layer cannot be cleared from here" \
  "$(rows_of 2 | paste -sd'|')" "Back"
rm -f "$SHINOBI_SYSTEM_CONFIG/default-provider"
drive provider "@ROW:ollama" "Back" "@ROW:groq" "@ESC"
check "Back shows the list again" "$(pickers)" "4"
check "and the list is the same" "$(rows_of 3 | wc -l)" "$(rows_of 1 | wc -l)"

echo "== clearing your default =="
printf 'openai\n' >"$user_default"
before="$(acount provider.default)"
drive provider "@ROW:openai" "Clear my default"
check "the file is gone" "$([[ -e $user_default ]] && echo present || echo gone)" "gone"
check "one audit record" "$(($(acount provider.default) - before))" "1"
check "the operator is told" "$(contains "$(all_notes)" 'cleared your default provider')" "yes"

echo "== what is typed is never run =="
printf 'openai\n' >"$user_default"
before="$(acount provider.default)"
for typed in "--clear" "--json" "ollama" "openai" " ollama" "ollama; touch $work/pwned" '$(touch '"$work"'/pwned)' "ollama   local  ready" ""; do
  drive provider "$typed"
  check "list, typed '${typed:0:30}': the default is untouched" "$(current_default)" "openai"
  check "list, typed '${typed:0:30}': nothing was audited" "$(($(acount provider.default) - before))" "0"
  check "list, typed '${typed:0:30}': no action list was shown" "$(pickers)" "1"
done
check "nothing ran a typed command" "$([[ -e $work/pwned ]] && echo ran || echo clean)" "clean"
drive provider "--clear"
check "typing into the list says it was not a provider" "$(contains "$(all_notes)" 'not a provider on the list')" "yes"

# An action that is not in the list shown for this provider is not run, whatever
# was typed, even when it is a real action for some other provider.
for typed in "Clear my default" "Store API key" "Forget stored API key" "--clear" "default ollama" "Back; touch $work/pwned"; do
  drive provider "@ROW:ollama" "$typed"
  check "action, typed '${typed:0:30}', on a local provider that is not the default: nothing changed" \
    "$(current_default)|$(($(acount provider.default) - before))|$(acount provider.key.forget)|$(kitty_calls)" "openai|0|0|0"
  check "action, typed '${typed:0:30}': the operator is told it was not offered" \
    "$(contains "$(all_notes)" 'not one of the actions offered')" "yes"
done
drive provider "@ROW:groq" "Clear my default"
check "'Clear my default' typed on a provider that is not the default does not clear it" "$(current_default)" "openai"
check "nothing ran a typed action" "$([[ -e $work/pwned ]] && echo ran || echo clean)" "clean"
rm -f "$user_default"

echo "== storing a key opens a terminal and never takes one =="
drive provider "@ROW:openai" "Store API key"
check "the terminal is started once" "$(kitty_calls)" "1"
check "from an argument vector, with the id as one argument" \
  "$(kitty_args)" "--hold|--title|shinobi-provider-key|-e|shinobi-provider|key|openai|"
check "the menu itself stored nothing and recorded nothing" "$(acount provider.key.set)" "0"
check "and ran no other command in the meantime" "$([[ -e $XDG_STATE_HOME/shinobi/providers/openai.key ]] && echo key || echo none)" "none"

# Without kitty the menu says so, and says what to run instead. The PATH here is
# a directory of links to just the tools the menu needs, so a kitty installed on
# the machine running the test cannot be found.
bare="$work/bare"
mkdir -p "$bare"
for tool in bash env jq python3 mktemp rm cat dirname readlink head sed awk date id tr wc grep; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -n "$src" ]]; then ln -sf "$src" "$bare/$tool"; fi
done
ln -sf "$FAKES/wofi" "$bare/wofi"
ln -sf "$FAKES/notify-send" "$bare/notify-send"
rm -f "$T"/picker.* "$T"/notify.* "$T"/kitty.*
printf '%s\n' "@ROW:openai" "Store API key" >"$T/answers"
rc=0
PATH="$bare:$ROOT/bin" "$ROOT/bin/shinobi-menu" provider >/dev/null 2>"$work/menu.err" || rc=$?
check "with no kitty installed: the menu does not die silently" "$rc" "0"
check "and no terminal was started" "$(kitty_calls)" "0"
check "and says what to run instead" "$(contains "$(all_notes)" "shinobi provider key openai")" "yes"

echo "== forgetting a key asks first =="
printf 'sk-test-0123456789\n' | shinobi-provider key openai >/dev/null
keyfile="$XDG_STATE_HOME/shinobi/providers/openai.key"
before="$(acount provider.key.forget)"
drive provider "@ROW:openai" "Forget stored API key" "Keep it"
check "declining keeps the key" "$([[ -e $keyfile ]] && echo kept || echo gone)" "kept"
check "and records nothing" "$(($(acount provider.key.forget) - before))" "0"
check "the confirmation names the provider" "$(contains "$(rows_of 3)" 'Forget the key for openai')" "yes"
for typed in "yes" "Forget the key for groq" "forget the key for openai" "Forget the key for openai " ""; do
  drive provider "@ROW:openai" "Forget stored API key" "$typed"
  check "typing '${typed:0:30}' at the confirmation does not forget" "$([[ -e $keyfile ]] && echo kept || echo gone)" "kept"
done
drive provider "@ROW:openai" "Forget stored API key" "Forget the key for openai"
check "confirming forgets it" "$([[ -e $keyfile ]] && echo kept || echo gone)" "gone"
check "with one audit record" "$(($(acount provider.key.forget) - before))" "1"
check "and tells the operator" "$(contains "$(all_notes)" 'removed the key for openai')" "yes"
check "no key is anywhere in what was shown or audited" \
  "$(contains "$(all_notes)$(cat "$audit")" 'sk-test-0123456789')" "no"

echo "== what the commands say reaches the operator =="
# A setting that cannot be written: the CLI exits 1 and says why.
mv "$XDG_CONFIG_HOME/shinobi" "$XDG_CONFIG_HOME/shinobi.aside"
printf 'in the way' >"$XDG_CONFIG_HOME/shinobi"
drive provider "@ROW:ollama" "Make this the default"
check "a refused change is shown, with the exit status" "$(contains "$(all_notes)" 'exited with status 1')" "yes"
check "and the reason" "$(contains "$(all_notes)" 'shinobi-provider:')" "yes"
check "and is not reported as done" "$(contains "$(all_notes)" 'default provider is now')" "no"
check "the menu ends cleanly" "$rc" "0"
rm -f "$XDG_CONFIG_HOME/shinobi"
mv "$XDG_CONFIG_HOME/shinobi.aside" "$XDG_CONFIG_HOME/shinobi"

# A provider manifest that does not parse: readiness fails, and the menu says so
# instead of showing an empty list or nothing.
badprov="$work/badprov"
mkdir -p "$badprov"
printf 'this is = not [valid toml\n' >"$badprov/broken.toml"
rc=0
rm -f "$T"/picker.* "$T"/notify.*
: >"$T/answers"
SHINOBI_PROVIDERS_DIR="$badprov" "$ROOT/bin/shinobi-menu" provider >/dev/null 2>&1 || rc=$?
check "a manifest that does not parse: the menu exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "yes"
check "it says it cannot read the providers" "$(contains "$(all_notes)" 'Cannot read the providers')" "yes"
check "and shows the reason" "$(contains "$(all_notes)" 'shinobi-provider:')" "yes"
check "it did not show an empty list" "$(pickers)" "0"

echo "== an id that is not shaped like one never reaches argv =="
# A stand-in `shinobi-provider` whose report is hostile: an id that would be read
# as a flag, an id with a path in it, a manifest string with a newline in it that
# would split a row, and one honest provider. It also logs every command it is
# given, so what the menu actually ran can be read back.
stub="$work/stub"
mkdir -p "$stub"
cat >"$stub/shinobi-provider" <<'EOF'
#!/usr/bin/env bash
T="${FAKE_T:?}"
if [[ "$1" == readiness ]]; then
  cat "$T/canned.json"
  # A report that arrives with a failing exit status is not to be believed.
  if [[ -e "$T/readiness.rc" ]]; then
    echo "boom: the readiness check itself failed" >&2
    exit "$(cat "$T/readiness.rc")"
  fi
  exit 0
fi
printf '%s\0' "$@" >>"$T/stub.argv"
printf '\n' >>"$T/stub.calls"
echo "-leading dash in the output"
EOF
chmod +x "$stub/shinobi-provider"
cat >"$T/canned.json" <<'EOF'
{
  "engagement": "engagement acme",
  "profile": "operator",
  "cloud_cleared": false,
  "default": {"id": null, "source": "none", "problem": null, "usable": false, "blockers": []},
  "any_usable": true,
  "providers": [
    {"id": "--clear", "name": "x", "egress": "local", "default_model": "m", "requires_key": false, "default": false, "usable": true, "blockers": []},
    {"id": "../etc/passwd", "name": "x", "egress": "local", "default_model": "m", "requires_key": false, "default": false, "usable": true, "blockers": []},
    {"id": "Upper", "name": "x", "egress": "local", "default_model": "m", "requires_key": false, "default": false, "usable": true, "blockers": []},
    {"id": "honest", "name": "x", "egress": "cloud", "default_model": "m", "requires_key": true, "default": false, "usable": false,
     "blockers": ["first line\nfake-id   local  ready"]}
  ]
}
EOF
rm -f "$T/stub.argv" "$T/stub.calls"
rm -f "$T"/picker.* "$T"/notify.* "$T"/kitty.*
printf '%s\n' "@ROW:honest" "Make this the default" >"$T/answers"
rc=0
PATH="$stub:$PATH" "$ROOT/bin/shinobi-menu" provider >/dev/null 2>"$work/menu.err" || rc=$?
check "only the well-formed id is offered" "$(rows_of 1 | awk '{print $1}')" "honest"
check "and a newline in a reason does not make a second row" "$(rows_of 1 | wc -l)" "1"
check "the reason is on the one row, flattened" "$(contains "$(rows_of 1)" 'first line fake-id')" "yes"
check "the command that ran is exactly: default honest" "$(tr '\0' '|' <"$T/stub.argv")" "default|honest|"
check "one command ran" "$(wc -l <"$T/stub.calls")" "1"
check "output that begins with a dash is shown as text, after --" "$(note 1 0)|$(note 1 -1)" "--|-leading dash in the output"

# Valid JSON on stdout does not make a report trustworthy when the command that
# wrote it failed: the exit status is part of the answer.
printf '1' >"$T/readiness.rc"
rm -f "$T/stub.argv" "$T/stub.calls"
rm -f "$T"/picker.* "$T"/notify.* "$T"/kitty.*
: >"$T/answers"
rc=0
PATH="$stub:$PATH" "$ROOT/bin/shinobi-menu" provider >/dev/null 2>&1 || rc=$?
rm -f "$T/readiness.rc"
check "a failing readiness command with parseable output: the menu exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "yes"
check "it says it cannot read the providers, and why" \
  "$(contains "$(all_notes)" 'Cannot read the providers')|$(contains "$(all_notes)" 'boom: the readiness check itself failed')" "yes|yes"
check "and shows no list to act on" "$(pickers)" "0"

echo "== the menu stays out of the gate =="
check "no route of the provider menu runs the LLM client or the gate" \
  "$(grep -v '^[[:space:]]*#' "$ROOT/bin/shinobi-menu" | grep -c 'shinobi-llm\|llmctl\|shinobi-egress\|egress\.py' || true)" "0"
check "every command it runs is one of the provider verbs" \
  "$(grep -o 'provider_run [a-z-]*' "$ROOT/bin/shinobi-menu" | awk '{print $2}' | sort -u | paste -sd,)" "default,forget"

echo
if [[ $failures -eq 0 ]]; then
  echo "menu-provider-test: PASS ($checks checks)"
else
  echo "menu-provider-test: FAIL ($failures of $checks checks)"
  exit 1
fi
