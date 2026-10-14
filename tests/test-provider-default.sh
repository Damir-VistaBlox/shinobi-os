#!/usr/bin/env bash
# Tests the default provider: the one `shinobi llm ask` uses when none is named.
#
# A default is a selection and nothing more. It must never be able to waive a
# clearance, which is why the egress gate does not read it at all, and why every
# case here that matters is a refusal: a setting that cannot be believed has to
# stop the command, not be replaced by whichever provider happens to be ready.
#
# Also covered, because a default is only useful if the things around it are
# honest: readiness must agree with the gate about what is usable, a key piped in
# by a secret manager (which ends in a newline) must be accepted with exactly that
# one newline dropped, changes to a setting or a stored key must leave one audit
# record each and none for a refused attempt, no record or output may carry a key,
# and a local provider must not make `shinobi llm ask` wait on an approval nothing
# will read.
#
# The LLM client is run through libexec/shinobi/shinobi-llmctl directly, not
# through bin/shinobi-llm: that wrapper prefers an installed /usr/lib/shinobi
# copy, and on a machine with the package a suite that went through it would be
# testing the installed client instead of this tree.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# The setting files this test writes by hand have to be ones the code is willing
# to trust (not writable by group or others), whatever umask the machine has.
umask 022

# A live image keeps keys in the kernel keyring, and this suite stores and forgets
# keys. It must not touch a keyring it cannot sandbox.
if [[ -e /run/live/medium/live/filesystem.squashfs ]]; then
  echo "provider-default-test: SKIP (live image: keys live in the kernel keyring, which this suite cannot sandbox)"
  exit 0
fi

work="$(mktemp -d)"
fake_pids=()
cleanup() {
  for pid in "${fake_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  rm -rf -- "$work"
}
trap cleanup EXIT

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

# Everything the commands touch is this test's own. The three config layers are
# separate directories so the precedence between them can be exercised, and the
# provider search path is pinned to the shipped manifests until the LLM section.
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
  XDG_RUNTIME_DIR="$work/run" SHINOBI_SYSTEM_CONFIG="$work/etc" SHINOBI_DEFAULTS_DIR="$work/share" \
  SHINOBI_PROVIDERS_DIR="$ROOT/providers" SHINOBI_ENGAGEMENTS_DIR="$work/engagements"
unset SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR SHINOBI_STATE_FILE SHINOBI_AUDIT_FILE
mkdir -p "$HOME" "$XDG_CONFIG_HOME/shinobi" "$XDG_STATE_HOME/shinobi" "$SHINOBI_SYSTEM_CONFIG" \
  "$SHINOBI_DEFAULTS_DIR" "$SHINOBI_ENGAGEMENTS_DIR"
export PATH="$ROOT/bin:$PATH"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

user_file="$XDG_CONFIG_HOME/shinobi/default-provider"
system_file="$SHINOBI_SYSTEM_CONFIG/default-provider"
packaged_file="$SHINOBI_DEFAULTS_DIR/default-provider"
audit="$XDG_STATE_HOME/shinobi/audit.jsonl"
approvals="$XDG_STATE_HOME/shinobi/approvals"
keyfile="$XDG_STATE_HOME/shinobi/providers/openai.key"

# run <cmd...>: out, err and rc from one command, without ever aborting the suite.
run() {
  rc=0
  out="$("$@" 2>"$work/err")" || rc=$?
  err="$(<"$work/err")"
}
# run_stdin <text> <cmd...>: the same, with <text> on the command's stdin.
run_stdin() {
  local input="$1"
  shift
  rc=0
  out="$(printf '%s' "$input" | "$@" 2>"$work/err")" || rc=$?
  err="$(<"$work/err")"
}
# jq_py <expr>: evaluate a Python expression over the JSON on stdin as `d`.
jq_py() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
# The client, from this tree, with a ceiling: a regression that made it wait on an
# approval would otherwise hang the suite for ten minutes instead of failing it.
shinobi_llm() { timeout 60 python3 "$ROOT/libexec/shinobi/shinobi-llmctl" "$@"; }

# acount <capability>: how many audit records carry it. Counting, not grepping for
# presence, is what tells "one record per change" from "some record exists".
acount() {
  local n
  n="$(grep -c "\"capability\": \"$1\"" "$audit" 2>/dev/null || true)"
  echo "${n:-0}"
}
# delta <capability> <count-before>: records added since.
delta() { echo $(($(acount "$1") - $2)); }

# An engagement for the gate to read. Empty argument: none.
BASE_SCOPE=$'window:\n  start: "2020-01-01"\n  end: "2030-01-01"\ntargets: ["127.0.0.1"]\n'
engagement() {
  if [[ -z ${1:-} ]]; then
    rm -f "$XDG_STATE_HOME/shinobi/current-engagement"
    return
  fi
  mkdir -p "$SHINOBI_ENGAGEMENTS_DIR/acme"
  printf '%s' "$1" >"$SHINOBI_ENGAGEMENTS_DIR/acme/scope.yaml"
  chmod 600 "$SHINOBI_ENGAGEMENTS_DIR/acme/scope.yaml"
  printf 'acme' >"$XDG_STATE_HOME/shinobi/current-engagement"
  printf 'operator' >"$XDG_STATE_HOME/shinobi/profile"
}
# ready_usable <id>: what readiness says. gate_verdict <id>: what the gate says.
ready_usable() {
  shinobi-provider readiness --json | jq_py "[p['usable'] for p in d['providers'] if p['id'] == '$1'][0]"
}
gate_verdict() {
  python3 - "$1" <<'PYEOF' 2>/dev/null
import sys
from shinobi_control import egress
try:
    egress.authorize(sys.argv[1], "a question")
except egress.EgressRefused:
    print("refused")
else:
    print("allowed")
PYEOF
}

echo "== nothing set =="
run shinobi-provider default
check "prints nothing on stdout" "$out" ""
check "says how to set one" "$(contains "$err" 'shinobi provider default <id>')" "yes"
check "and is not an error" "$rc" "0"
check "json reports no default" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["source"], d["valid"])')" "(None, 'none', False)"

echo "== choosing a cloud provider =="
run shinobi-provider default openai
check "succeeds" "$rc" "0"
check "names the provider and its egress" "$(contains "$out" 'default provider is now openai (cloud)')" "yes"
check "says plainly that it waives nothing" "$(contains "$out" 'waives nothing')" "yes"
check "says what every turn still needs" "$(contains "$out" 'your approval')" "yes"
check "points out that no key is stored yet" "$(contains "$out" 'shinobi provider key openai')" "yes"
check "writes the user's setting" "$(cat "$user_file")" "openai"
check "and shows it back" "$(shinobi-provider default)" "openai"
check "json carries the source and egress" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["source"], d["valid"], d["egress"])')" \
  "('openai', 'user', True, 'cloud')"

echo "== choosing a local provider =="
run shinobi-provider default ollama
check "succeeds" "$rc" "0"
check "says no per-turn approval is needed" "$(contains "$out" 'no per-turn approval')" "yes"
check "but that an engagement is still required" "$(contains "$out" 'active engagement is still required')" "yes"

echo "== what is refused, and what it leaves alone =="
shinobi-provider default openai >/dev/null
run shinobi-provider default nonesuch
check "an unknown provider is refused" "$rc" "1"
check "naming the missing manifest" "$(contains "$err" 'no provider manifest')" "yes"
check "and the setting is unchanged" "$(cat "$user_file")" "openai"
run shinobi-provider default '../escape'
check "a path-like id is refused" "$rc" "1"
check "and the setting is unchanged" "$(cat "$user_file")" "openai"
run shinobi-provider default 'a b'
check "an id with a space is refused" "$rc" "1"
run shinobi-provider default openai ollama
check "two ids are a usage error" "$rc" "2"
run shinobi-provider default openai --clear
check "an id together with --clear is a usage error" "$rc" "2"
run shinobi-provider default --claer
check "a mistyped flag is a usage error, not 'show the default'" "$rc" "2"
run shinobi-provider default ollama --claer
check "nor does it set a default while ignoring the typo" "$rc" "2"
check "none of these touched the setting" "$(cat "$user_file")" "openai"

echo "== layers: user over system over packaged =="
shinobi-provider default --clear >/dev/null
printf 'anthropic\n' >"$packaged_file"
check "the packaged default applies last" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["source"])')" "('anthropic', 'packaged')"
printf 'vllm\n' >"$system_file"
check "the system default beats the packaged one" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["source"])')" "('vllm', 'system')"
shinobi-provider default ollama >/dev/null
check "the user's choice beats both" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["source"])')" "('ollama', 'user')"
check "choosing never writes the system layer" "$(cat "$system_file")" "vllm"
run shinobi-provider default --clear
check "clearing removes the user's choice" "$([[ -e $user_file ]] && echo present || echo gone)" "gone"
check "and says which default still applies" "$(contains "$out" 'the system default still applies: vllm')" "yes"
check "which is the one now in force" "$(shinobi-provider default)" "vllm"
rm -f "$system_file" "$packaged_file"
run shinobi-provider default --clear
check "clearing when nothing is set says so" "$(contains "$out" 'no default provider set')" "yes"
printf 'gone\n' >"$system_file"
shinobi-provider default ollama >/dev/null
run shinobi-provider default --clear
check "clearing says when the layer underneath cannot be used" \
  "$(contains "$out" 'system default is set but cannot be used')" "yes"
check "instead of claiming it still applies" "$(contains "$out" 'still applies')" "no"
rm -f "$system_file"

echo "== a setting that cannot be believed stops everything, in every layer =="
# The failure being guarded against is a bad value in a HIGHER layer being skipped
# in favour of a lower one: that routes a prompt to a provider nobody chose. So
# each layer is made bad in turn, with a perfectly good value underneath it.
printf 'vllm\n' >"$system_file"
printf 'not a provider id!!\n' >"$user_file"
run shinobi-provider default
check "a malformed user value is an error" "$rc" "1"
check "and says what is wrong" "$(contains "$err" 'does not hold a provider id')" "yes"
check "and the lower layer is NOT used instead" "$(contains "$out" 'vllm')" "no"
check "json says it is not valid" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["source"], d["valid"])')" "(None, 'user', False)"
check "json reports it in the body and still exits 0, by design" \
  "$(shinobi-provider default --json >/dev/null; echo $?)" "0"
: >"$user_file"
run shinobi-provider default
check "an empty file shadows the lower layer rather than being skipped" "$rc" "1"
printf 'gone\n' >"$user_file"
run shinobi-provider default
check "a provider that no longer exists is an error" "$rc" "1"
check "naming it" "$(contains "$err" "no provider manifest for 'gone'")" "yes"
check "json keeps the id but says it is not valid" \
  "$(shinobi-provider default --json | jq_py '(d["default"], d["valid"])')" "('gone', False)"
rm -f "$user_file"

printf 'anthropic\n' >"$packaged_file"
printf 'not a provider id!!\n' >"$system_file"
run shinobi-provider default
check "a malformed SYSTEM value is an error" "$rc" "1"
check "that names the system file" "$(contains "$err" "$system_file")" "yes"
check "and the packaged default beneath it is NOT used" "$(contains "$out" 'anthropic')" "no"
chmod 666 "$system_file"
run shinobi-provider default
check "a system file anyone can write is not trusted either" "$rc" "1"
printf 'gone\n' >"$system_file"
chmod 644 "$system_file"
run shinobi-provider default
check "a dangling SYSTEM value is an error" "$rc" "1"
check "naming the missing manifest" "$(contains "$err" "no provider manifest for 'gone'")" "yes"
rm -f "$system_file"
printf 'not a provider id!!\n' >"$packaged_file"
run shinobi-provider default
check "a malformed PACKAGED value is an error" "$rc" "1"
check "that names the packaged file" "$(contains "$err" "$packaged_file")" "yes"
rm -f "$packaged_file"

echo "== the file itself has to be trustworthy =="
ln -s /etc/hostname "$user_file"
run shinobi-provider default
check "a symlink is not read" "$rc" "1"
check "and says so" "$(contains "$err" 'is a symlink')" "yes"
rm -f "$user_file"
head -c 400 /dev/zero | tr '\0' 'a' >"$user_file"
run shinobi-provider default
check "an oversized file is refused unread" "$(contains "$err" 'not a small regular file')" "yes"
rm -f "$user_file"
printf 'ollama\n' >"$user_file"
chmod 666 "$user_file"
run shinobi-provider default
check "a file anyone can write is not trusted" "$rc" "1"
check "and says why" "$(contains "$err" 'writable by its group or others')" "yes"
chmod 664 "$user_file"
run shinobi-provider default
check "nor is one its group can write" "$rc" "1"
chmod 644 "$user_file"
check "the same file, once only its owner can write it, is accepted" "$(shinobi-provider default)" "ollama"
rm -f "$user_file"
# A FIFO must be refused, not waited on: a read that blocks would hang every
# command that asks for the default.
mkfifo "$user_file"
run timeout 10 shinobi-provider default
check "a FIFO is refused rather than hanging (a timeout would be 124)" "$rc" "1"
check "and says so" "$(contains "$err" 'not a small regular file')" "yes"
rm -f "$user_file"
# An XDG base directory has to be absolute. A relative one would make the setting
# that decides where prompts go depend on the directory the command ran from.
mkdir -p "$work/cwd/rel/shinobi"
printf 'openai\n' >"$work/cwd/rel/shinobi/default-provider"
check "a relative XDG_CONFIG_HOME is ignored" \
  "$(cd "$work/cwd" && XDG_CONFIG_HOME=rel shinobi-provider default --json | jq_py 'd["default"]')" "None"
if [[ $(id -u) -ne 0 ]]; then
  chmod 500 "$XDG_CONFIG_HOME/shinobi"
  run shinobi-provider default ollama
  check "an unwritable config directory is a clean error" "$rc" "1"
  check "not a traceback" "$(contains "$err" 'Traceback')" "no"
  check "that says what failed" "$(contains "$err" 'cannot write the default provider')" "yes"
  chmod 700 "$XDG_CONFIG_HOME/shinobi"
else
  echo "  skip an unwritable config directory (root writes anywhere)"
fi

echo "== readiness agrees with the gate =="
# A local provider reported as ready when the gate would refuse it is a promise
# broken on the first question. Each state is checked against the gate itself,
# for a provider that needs no key and no approval, so that the only thing that
# can differ is the engagement.
shinobi-provider default ollama >/dev/null
ollama_model="$(python3 -c 'from shinobi_control import providerctl as p; print(p.get("ollama").default_model)')"

engagement ""
out="$(shinobi-provider readiness --json)"
check "no engagement: every provider is blocked, local ones included" \
  "$(jq_py 'all(any("no usable engagement" in b for b in p["blockers"]) for p in d["providers"])' <<<"$out")" "True"
check "each row gets one short blocker, not the engagement's whole sentence" \
  "$(jq_py '[p["blockers"] for p in d["providers"] if p["id"] == "ollama"][0]' <<<"$out")" \
  "['no usable engagement (see the engagement line)']"
check "the reason is given once, in the engagement field" \
  "$(jq_py '"no active engagement" in d["engagement"]' <<<"$out")" "True"
check "the default block carries the same blocker" \
  "$(jq_py '"no usable engagement" in d["default"]["blockers"][0]' <<<"$out")" "True"
check "readiness says unusable" "$(ready_usable ollama)" "False"
check "and the gate agrees" "$(gate_verdict ollama)" "refused"

engagement "$BASE_SCOPE"
check "an engagement with no llm block: readiness says usable" "$(ready_usable ollama)" "True"
check "and the gate agrees" "$(gate_verdict ollama)" "allowed"

engagement "${BASE_SCOPE}"$'llm:\n  models: ["some-other-model"]\n'
check "a model allowlist that excludes the default model: readiness says unusable" "$(ready_usable ollama)" "False"
check "and names the field" \
  "$(shinobi-provider readiness --json | jq_py 'any("llm.models" in b for p in d["providers"] if p["id"] == "ollama" for b in p["blockers"])')" "True"
check "and the gate agrees" "$(gate_verdict ollama)" "refused"
check "so the default is not usable" "$(shinobi-provider readiness --json | jq_py 'd["default"]["usable"]')" "False"

engagement "${BASE_SCOPE}"$"llm:"$'\n'"  models: [\"$ollama_model\"]"$'\n'
check "an allowlist that includes it: readiness says usable (the positive control)" "$(ready_usable ollama)" "True"
check "and the gate agrees" "$(gate_verdict ollama)" "allowed"

engagement "$BASE_SCOPE"
out="$(shinobi-provider readiness --json)"
check "the default block reflects a usable default" \
  "$(jq_py '(d["default"]["id"], d["default"]["source"], d["default"]["usable"])' <<<"$out")" "('ollama', 'user', True)"
check "exactly one row is marked as the default" \
  "$(jq_py '[p["id"] for p in d["providers"] if p["default"]]' <<<"$out")" "['ollama']"
run shinobi-provider readiness
check "the text report names the default" "$(contains "$out" 'default:    ollama (user)')" "yes"
check "and marks its row" "$(grep -E '^ok  +ollama' <<<"$out" | grep -c '(default)')" "1"

echo "== the gate never reads the default =="
# The central design claim, checked two ways. Behaviourally: in a world where the
# default WOULD be allowed (the positive control above), an empty provider id is
# still refused, so the gate cannot be adopting the default for it. And
# statically: nothing under the gate or the client mentions the setting.
check "an empty provider id is refused even though the default would be allowed" \
  "$(python3 - <<'PYEOF' 2>/dev/null
from shinobi_control import egress
try:
    egress.authorize("", "a question")
except egress.EgressRefused:
    print("refused")
else:
    print("allowed")
PYEOF
)" "refused"
check "the egress gate and the client never mention the default" \
  "$(python3 - "$ROOT" <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]) / "libexec/shinobi/shinobi_control"
files = [root / "egress.py", *sorted((root / "llm").glob("*.py"))]
pattern = re.compile(r"default_provider|resolve_provider_id|DEFAULT_FILE|default-provider")
print(sum(len(pattern.findall(f.read_text())) for f in files))
PYEOF
)" "0"
check "an empty argument is not read as 'use the default'" \
  "$(python3 -c 'from shinobi_control import providerctl as p; print(repr(p.resolve_provider_id("")))')" "''"

echo "== a key arriving from a secret manager =="
# Most secret managers, and plain `echo`, end their output with a newline. That
# one is the terminator and is dropped; a newline anywhere else is still refused.
# What is stored is read back as bytes: get_key() strips on read, which would
# hide a terminator that was left on.
stored_bytes() { python3 -c 'import sys; print(open(sys.argv[1], "rb").read())' "$keyfile"; }
no_echo() { check "$1" "$(contains "$out$err" "$2")" "no"; }

run_stdin $'sk-from-a-manager\n' shinobi-provider key openai
check "a key ending in a newline is stored" "$rc" "0"
check "without the newline" "$(stored_bytes)" "b'sk-from-a-manager'"
no_echo "and the key is not echoed" 'sk-from-a-manager'
run_stdin $'sk-two\r\n' shinobi-provider key openai
check "a CRLF terminator is dropped as one unit" "$(stored_bytes)" "b'sk-two'"
run_stdin $'sk-a\n\n' shinobi-provider key openai
check "only ONE trailing newline is dropped: two are refused" "$rc" "1"
no_echo "and the refusal does not repeat the key" 'sk-a'
run_stdin $'part-one\npart-two\n' shinobi-provider key openai
check "a newline inside the key is still refused" "$rc" "1"
no_echo "and the refusal does not repeat it" 'part-one'
run_stdin $'\n' shinobi-provider key openai
check "an empty key is still refused" "$rc" "1"

# A key becomes an HTTP header, and a control character in one makes the HTTP
# client raise an exception whose text is the whole header, key included. So a
# key with one is refused where it is stored, and again where it is read, in case
# the file was written before the check existed.
run_stdin $'sk-abc\rdef' shinobi-provider key openai
check "a key with a bare carriage return is refused" "$rc" "1"
no_echo "without showing it" 'sk-abc'
run_stdin $'sk-caf\xc3\xa9' shinobi-provider key openai
check "a key with non-ASCII characters is refused" "$rc" "1"
printf 'sk-old\rkey' >"$keyfile"
chmod 600 "$keyfile"
msg="$(python3 -c '
from shinobi_control import credentials
try:
    credentials.get_key("openai")
except credentials.CredentialError as exc:
    print(exc)
else:
    print("returned a key")
')"
check "a stored key with a control character is refused on read" "$(contains "$msg" 'printable ASCII')" "yes"
check "without showing it" "$(contains "$msg" 'sk-old')" "no"
rm -f "$keyfile"

echo "== one audit record per change, none for a refused attempt, never a key =="
before=$(acount provider.key.set)
run_stdin $'sk-audit-one\n' shinobi-provider key openai
check "an accepted key adds exactly one record" "$(delta provider.key.set "$before")" "1"
before=$(acount provider.key.set)
run_stdin $'sk-bad\rkey' shinobi-provider key openai
check "a refused key adds none" "$(delta provider.key.set "$before")" "0"
before=$(acount provider.key.forget)
shinobi-provider forget openai >/dev/null
check "forgetting a stored key adds exactly one" "$(delta provider.key.forget "$before")" "1"
before=$(acount provider.key.forget)
shinobi-provider forget openai >/dev/null
check "forgetting when there is nothing to forget adds none" "$(delta provider.key.forget "$before")" "0"
before=$(acount provider.default)
shinobi-provider default ollama >/dev/null
check "setting a default adds exactly one" "$(delta provider.default "$before")" "1"
check "and that record says what was set" "$(tail -1 "$audit" | jq_py 'd["detail"]')" "default provider set to ollama"
before=$(acount provider.default)
shinobi-provider default --clear >/dev/null
check "clearing it adds exactly one" "$(delta provider.default "$before")" "1"
check "and that record says it was cleared" "$(tail -1 "$audit" | jq_py 'd["detail"]')" "default provider cleared"
before=$(acount provider.default)
shinobi-provider default --clear >/dev/null
check "clearing when there is nothing to clear adds none" "$(delta provider.default "$before")" "0"
before=$(acount provider.default)
shinobi-provider default nonesuch >/dev/null 2>&1 || true
check "a refused default adds none" "$(delta provider.default "$before")" "0"
check "no key appears anywhere in the audit journal" \
  "$(grep -c -E 'sk-from-a-manager|sk-two|sk-a|part-one|sk-audit-one|sk-bad|sk-abc' "$audit" || true)" "0"
events="$(shinobi-event recent)"
check "the key change reached the event bus with its meaning" \
  "$(jq_py '[e["payload"] for e in d if e["event"] == "provider.key.changed"][-1]' <<<"$events")" \
  "{'provider': 'openai', 'stored': False}"
check "and so did the default change" \
  "$(jq_py '[e["payload"] for e in d if e["event"] == "provider.default.changed"][-1]' <<<"$events")" \
  "{'provider': None}"
check "no key appears on the event bus" \
  "$(grep -c -E 'sk-from-a-manager|sk-two|sk-audit-one|part-one' <<<"$events" || true)" "0"

# Who made the change comes from the account the process runs as. $USER is
# whatever the caller exported, so a record built from it can name anyone.
USER=mallory shinobi-provider default ollama >/dev/null
check "the audit actor is the real account, not \$USER" \
  "$(tail -1 "$audit" | jq_py 'd["actor"]')" "$(id -un)"

# The change has happened by the time it is recorded, so a failed record cannot
# undo it. What it must not do is look like success: the command says so and
# exits non-zero, so a script or the desktop does not read it as a clean change.
rm -f "$user_file"
mkdir -p "$work/not-a-file"
run env SHINOBI_AUDIT_FILE="$work/not-a-file" shinobi-provider default ollama
check "a change that cannot be audited exits non-zero" "$rc" "1"
check "and says the change was made but not recorded" "$(contains "$err" 'NOT be recorded')" "yes"
check "the change itself did happen" "$(cat "$user_file")" "ollama"
run env SHINOBI_AUDIT_FILE="$work/not-a-file" shinobi-provider default --clear
check "clearing is held to the same standard" "$rc" "1"
run_stdin $'sk-unaudited\n' env SHINOBI_AUDIT_FILE="$work/not-a-file" shinobi-provider key openai
check "and so is storing a key" "$rc" "1"
no_echo "which still does not show the key" 'sk-unaudited'
shinobi-provider forget openai >/dev/null 2>&1 || true
rm -rf "$work/not-a-file"

echo "== the LLM client and the default =="
# Two private local providers, each with its own real HTTP listener, and one cloud
# manifest. Which listener receives a prompt is the thing under test, so it is
# read off the listeners' own request history rather than inferred from stderr.
providers="$work/providers"
mkdir -p "$providers"
start_fake() { # start_fake <name> <reply>
  local name="$1" reply="$2"
  : >"$work/$name.history"
  FAKE_PORT_FILE="$work/$name.port" FAKE_HISTORY="$work/$name.history" FAKE_MODE=openai \
    python3 "$ROOT/tests/fixtures/fake-provider.py" \
    <<<"[{\"text\":\"$reply\"},{\"text\":\"$reply\"},{\"text\":\"$reply\"}]" 2>/dev/null &
  fake_pids+=("$!")
  for _ in $(seq 1 100); do
    [[ -s "$work/$name.port" ]] && break
    sleep 0.05
  done
  [[ -s "$work/$name.port" ]] || { echo "fake provider $name never bound" >&2; exit 1; }
  cat >"$providers/$name.toml" <<EOF
id = "$name"
name = "${name^}"
api = "openai-compatible"
base_url = "http://127.0.0.1:$(<"$work/$name.port")/v1"
egress = "local"
requires_key = false
default_model = "m"
reachable_on = ["127.0.0.1"]
EOF
}
start_fake lo "hello from lo"
start_fake other "hello from other"
# A literal public address, as test-egress.sh does, so nothing here ever needs DNS.
cat >"$providers/cl.toml" <<'EOF'
id = "cl"
name = "Cl"
api = "openai"
base_url = "https://93.184.216.34/v1"
egress = "cloud"
requires_key = true
default_model = "m"
EOF
export SHINOBI_PROVIDERS_DIR="$providers"
engagement "$BASE_SCOPE"
requests() { wc -l <"$work/$1.history" | tr -d ' '; }
rm -rf "$approvals"

shinobi-provider default --clear >/dev/null
run_stdin "a question" shinobi_llm ask --server '' --no-wait
check "no provider and no default is refused" "$rc" "1"
check "and says how to choose one" "$(contains "$err" 'shinobi provider default')" "yes"
check "and nothing was sent to anyone" "$(( $(requests lo) + $(requests other) ))" "0"
check "nor was an approval requested" "$(ls "$approvals" 2>/dev/null | wc -l)" "0"

shinobi-provider default lo >/dev/null
run shinobi_llm check
check "check with no provider uses the default" "$(grep -c '^lo: Lo' <<<"$out")" "1"
check "and says it is the default" "$(contains "$out" '(the default provider)')" "yes"
check "check --json names the provider it described" \
  "$(shinobi_llm check --json | jq_py '(d["id"], d["from_default"])')" "('lo', True)"
check "and whether that was the default" \
  "$(shinobi_llm check other --json | jq_py '(d["id"], d["from_default"])')" "('other', False)"

run_stdin "a question" shinobi_llm ask --server ''
check "an ask with no provider completes through the default" "$rc" "0"
check "and returns that provider's answer" "$out" "hello from lo"
check "says it used the default" "$(contains "$err" 'using the default provider: lo (local)')" "yes"
check "the default provider's listener got the prompt" "$(requests lo)" "1"
check "and no other listener did" "$(requests other)" "0"
check "a local provider asks for no approval" "$(ls "$approvals" 2>/dev/null | wc -l)" "0"

run_stdin "a question" shinobi_llm ask other --server ''
check "naming a provider overrides the default" "$out" "hello from other"
check "the named provider's listener got it" "$(requests other)" "1"
check "the default's listener did not get a second one" "$(requests lo)" "1"
check "and naming it does not announce a default" "$(contains "$err" 'using the default provider')" "no"

# --approval-id covers one turn of a CLOUD conversation. For a local provider
# nothing would ever read it, and the one-turn closure it installs would abort a
# conversation that has tool calls at its second turn.
run_stdin "a question" shinobi_llm ask lo --server '' --approval-id deadbeef
check "--approval-id does not stop a local conversation" "$rc" "0"
check "and says it was ignored" "$(contains "$err" '--approval-id is ignored')" "yes"

shinobi-provider default cl >/dev/null
rm -rf "$approvals"
before_lo="$(requests lo)"
run_stdin "a question" shinobi_llm ask --server '' --no-wait
check "a cloud default says what it is" "$(contains "$err" 'using the default provider: cl (cloud)')" "yes"
check "a cloud provider still asks for an approval" "$(ls "$approvals" 2>/dev/null | wc -l)" "1"
check "and says so" "$(contains "$err" 'requested for turn 1')" "yes"
check "and stops there: nothing further was sent" "$(contains "$err" 'so nothing further was sent')" "yes"
check "no listener saw a request" "$(requests lo)" "$before_lo"

# Prompts pasted into argv, in every shape, must not be repeated back.
shinobi-provider default --clear >/dev/null
printf 'gone\n' >"$user_file"
run_stdin "a question" shinobi_llm ask --server ''
check "a default that cannot be used stops the command" "$rc" "1"
check "naming why" "$(contains "$err" 'the default provider cannot be used')" "yes"
rm -f "$user_file"
run_stdin "" shinobi_llm ask 'what is open on 10.10.10.5?' --server ''
check "a prompt given as an argument is refused" "$rc" "1"
check "without repeating it" "$(contains "$err" '10.10.10.5')" "no"
check "and says why" "$(contains "$err" 'not accepted as an argument')" "yes"
run shinobi_llm check 'what is open on 10.10.10.5?'
check "check refuses it the same way" "$(contains "$err" '10.10.10.5')" "no"
run_stdin "" shinobi_llm ask 10.10.10.5 --server ''
check "an id-shaped argument that is no provider is refused" "$rc" "1"
check "without being repeated" "$(contains "$err" '10.10.10.5')" "no"
check "listing the providers that do exist instead" "$(contains "$err" 'known: cl, lo, other')" "yes"
run shinobi_llm check scanme.nmap.org
check "check does not quote a hostname back either" "$(contains "$err" 'scanme.nmap.org')" "no"
run shinobi_llm 'what is open on 10.10.10.5?'
check "a prompt where the subcommand goes is refused" "$rc" "1"
check "without being repeated" "$(contains "$err" '10.10.10.5')" "no"
run shinobi_llm ask lo --max-turns 'what is open on 10.10.10.5?'
check "nor is a prompt swallowed by a numeric option" "$(contains "$err" '10.10.10.5')" "no"
shinobi-provider default cl >/dev/null
rm -rf "$approvals"
run_stdin "a question" shinobi_llm ask '' --server '' --no-wait
check "an empty provider argument is refused" "$rc" "1"
check "and is not read as 'use the default'" "$(contains "$err" 'using the default provider')" "no"
check "so no approval is requested from anyone" "$(ls "$approvals" 2>/dev/null | wc -l)" "0"

echo
if ((failures > 0)); then
  printf 'provider-default-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nprovider-default-test: PASS\n' "$checks" "$checks"
