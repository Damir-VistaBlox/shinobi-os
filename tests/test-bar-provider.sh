#!/usr/bin/env bash
# The status bar's LLM pill: which provider the agent would use and, when it could not,
# the first thing in the way.
#
# The bar used to say "AI offline" for five different problems. The readiness report
# (`shinobi provider readiness --json`) already tells them apart; the pill is
# quickshell/ProviderStatus.js shortening that report. Quickshell is not available to a
# test (it needs a compositor), so what is checked here is everything around the pill
# that can be checked without one:
#
#   * the logic, run with node against the REAL report in every state an operator can be
#     in (nothing chosen, no engagement, an engagement that has not cleared cloud, a
#     session below operator, no key, a provider the engagement forbids, a default that
#     names nothing installed, a default file that is blank), and against reports that
#     are malformed, because a bar that shows a stale "ready" after the command broke is
#     worse than one that says it does not know;
#   * the exact command the bar runs, taken out of shell.qml, in the two cases that matter
#     (it answers with one line; it fails with an empty one);
#   * that shell.qml is wired to it and that every colour it asks the theme for exists in
#     every theme, because a theme that lacks one makes that part of the bar invisible.
#
# Needs node for the logic half: skipped, loudly, without it, unless SHINOBI_REQUIRE_NODE=1 (CI sets it).
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QS="$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell"
umask 022

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

section "the bar is wired to the report"
check "the helper is plain JavaScript that QML loads as a library" \
  "$(head -n 1 "$QS/ProviderStatus.js")" ".pragma library"
check "shell.qml imports it" \
  "$(grep -c '^import "ProviderStatus.js" as ProviderStatus$' "$QS/shell.qml" || true)" "1"
check "and asks for the readiness report, not for a guess" \
  "$(grep -c 'shinobi provider readiness --json' "$QS/shell.qml" || true)" "1"
check "the pill opens the provider menu when clicked" \
  "$(grep -c 'command: "shinobi-menu provider"' "$QS/shell.qml" || true)" "1"
check "that route exists in the menu" \
  "$(grep -cE '^[[:space:]]*provider\)' "$ROOT/bin/shinobi-menu" || true)" "1"
check "a failed probe is shown as unknown (the exit handler), not left as the last answer" \
  "$(grep -c 'onExited:.*updateProvider("")' "$QS/shell.qml" || true)" "1"
check "the report is refreshed when the engagement changes, since clearance is per engagement" \
  "$(grep -c 'if (changed) refreshProvider()' "$QS/shell.qml" || true)" "1"

section "every colour the bar asks for exists in every theme"
used="$(grep -oE 'theme\.[A-Za-z]+' "$QS/shell.qml" | sort -u | sed 's/^theme\.//')"
check "shell.qml uses colours (the check below would pass on an empty list)" \
  "$([[ -n $used ]] && echo yes || echo no)" "yes"
for theme_file in "$QS/Theme.qml" "$ROOT"/themes/*/quickshell.qml; do
  missing=""
  for token in $used; do
    grep -qE "^[[:space:]]*readonly property color $token:" "$theme_file" || missing+="$token "
  done
  check "${theme_file#"$ROOT"/} defines all of them" "${missing:-none}" "none"
done
check "the packaged Theme.qml is the default theme's file (shinobi theme set links the theme's file over it)" \
  "$(cmp -s "$QS/Theme.qml" "$ROOT/themes/kali-dark/quickshell.qml" && echo same || echo different)" "same"

if ! command -v node >/dev/null 2>&1; then
  if [[ ${SHINOBI_REQUIRE_NODE:-} == 1 ]]; then
    echo "  FAIL node is not installed, and SHINOBI_REQUIRE_NODE=1 says the pill's logic must run"
    printf '\nbar-provider-test: FAIL (node required)\n'
    exit 1
  fi
  echo
  echo "  skip: node is not installed, so the pill's logic was not run."
  echo "        The wiring checks above ran; the report-to-label checks did not."
  printf '\n%d/%d checks passed\n' "$((checks - failures))" "$checks"
  ((failures == 0)) && echo "bar-provider-test: PASS (logic skipped)" && exit 0
  echo "bar-provider-test: FAIL"
  exit 1
fi

# --- the real report, in every state ---------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
  XDG_RUNTIME_DIR="$work/run" SHINOBI_SYSTEM_CONFIG="$work/etc" SHINOBI_DEFAULTS_DIR="$work/share" \
  SHINOBI_PROVIDERS_DIR="$ROOT/providers" SHINOBI_ENGAGEMENTS_DIR="$work/engagements"
unset SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR SHINOBI_STATE_FILE SHINOBI_AUDIT_FILE
mkdir -p "$HOME" "$XDG_CONFIG_HOME/shinobi" "$XDG_STATE_HOME/shinobi" "$SHINOBI_SYSTEM_CONFIG" \
  "$SHINOBI_DEFAULTS_DIR" "$SHINOBI_ENGAGEMENTS_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export PATH="$ROOT/bin:$PATH"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

# A live image keeps keys in the kernel keyring, and this suite stores one.
if [[ -e /run/live/medium/live/filesystem.squashfs ]]; then
  echo "bar-provider-test: SKIP the report half (live image: keys live in the kernel keyring)"
  exit "$((failures > 0))"
fi

# pill <stdin>: "label<TAB>tone" for whatever the bar's probe would have handed over.
pill() { node "$ROOT/tests/bar-provider-summary.js" "$QS/ProviderStatus.js"; }
# from_report: the pill for the real report as it is right now. The probe prints the
# report on one line; `tr` does the same here.
from_report() { shinobi-provider readiness --json 2>/dev/null | tr -d '\n' | pill; }

BASE_SCOPE=$'window:\n  start: "2020-01-01"\n  end: "2030-01-01"\ntargets: ["127.0.0.1"]\n'
engagement() { # engagement <scope text> [profile]
  mkdir -p "$SHINOBI_ENGAGEMENTS_DIR/acme"
  printf '%s' "$1" >"$SHINOBI_ENGAGEMENTS_DIR/acme/scope.yaml"
  chmod 600 "$SHINOBI_ENGAGEMENTS_DIR/acme/scope.yaml"
  printf 'acme' >"$XDG_STATE_HOME/shinobi/current-engagement"
  printf '%s' "${2:-operator}" >"$XDG_STATE_HOME/shinobi/profile"
}
T=$'\t'

section "the pill, against the real report"
check "nothing chosen and nothing usable: nothing to nudge" "$(from_report)" "LLM none set${T}muted"
shinobi-provider default ollama >/dev/null
check "a default but no engagement: the gate refuses everything without one" \
  "$(from_report)" "LLM ollama · no engagement${T}warn"
engagement "$BASE_SCOPE"
check "a local default with an engagement can be used" "$(from_report)" "LLM ollama${T}good"
rm -f "$XDG_CONFIG_HOME/shinobi/default-provider"
check "an engagement and a usable provider but no choice: only the choice is missing" \
  "$(from_report)" "LLM none set${T}warn"
shinobi-provider default anthropic >/dev/null
check "a cloud default in an engagement that has not cleared cloud egress" \
  "$(from_report)" "LLM anthropic · not cleared${T}warn"
engagement "${BASE_SCOPE}llm:"$'\n'"  cloud: true"$'\n' observer
check "cleared, but the session is below operator" \
  "$(from_report)" "LLM anthropic · needs operator${T}warn"
engagement "${BASE_SCOPE}llm:"$'\n'"  cloud: true"$'\n' operator
check "cleared and operator, but no key stored" "$(from_report)" "LLM anthropic · no key${T}warn"
printf 'not-a-real-key\n' | shinobi-provider key anthropic >/dev/null 2>&1
check "with the key as well it can be used" "$(from_report)" "LLM anthropic${T}good"
shinobi-provider forget anthropic >/dev/null 2>&1 </dev/null
check "and forgetting the key puts the blocker back" "$(from_report)" "LLM anthropic · no key${T}warn"
shinobi-provider default ollama >/dev/null
engagement "${BASE_SCOPE}llm:"$'\n'"  providers: [\"openai\"]"$'\n'
check "a provider the engagement does not permit" "$(from_report)" "LLM ollama · not allowed here${T}warn"
engagement "${BASE_SCOPE}llm:"$'\n'"  models: [\"some-other-model\"]"$'\n'
check "a model the engagement does not permit" "$(from_report)" "LLM ollama · model not allowed${T}warn"
printf 'nonesuch' >"$XDG_CONFIG_HOME/shinobi/default-provider"
check "a default that names a provider that is not installed" \
  "$(from_report)" "LLM nonesuch · unknown provider${T}warn"
printf '  \n' >"$XDG_CONFIG_HOME/shinobi/default-provider"
check "a default file that holds no id" "$(from_report)" "LLM bad default${T}warn"

section "the exact command the bar runs"
probe="$(python3 - "$QS/shell.qml" <<'PYEOF'
import json, re, sys
text = open(sys.argv[1]).read()
block = text[text.index("id: providerProbe"):]
match = re.search(r'command:\s*(\[[^\]]*\])', block)
print(json.loads(match.group(1))[2])
PYEOF
)"
printf 'ollama' >"$XDG_CONFIG_HOME/shinobi/default-provider"
engagement "$BASE_SCOPE"
probe_out="$(sh -c "$probe")"
check "it prints exactly one line" "$(printf '%s\n' "$probe_out" | wc -l)" "1"
check "which is the report, and the pill reads it" "$(printf '%s' "$probe_out" | pill)" "LLM ollama${T}good"
# $(...) hides trailing newlines, so the last byte has to be looked at directly: the bar's line
# parser hands a line over when it sees the end of it, and `tr -d '\n'` removed that one too.
last_byte() { od -An -c | tr -d ' \n'; }
check "and the line is newline-terminated, so the bar's line parser hands it over" \
  "$(sh -c "$probe" | tail -c 1 | last_byte)" '\n'
probe_out="$(SHINOBI_PROVIDERS_DIR="$work/no-such-dir" sh -c "$probe")"
check "when the report cannot be produced it prints an empty line, not a half answer" "[$probe_out]" "[]"
check "even then it still ends in a newline, so the exit handler (not a parser timeout) reports it" \
  "$(SHINOBI_PROVIDERS_DIR="$work/no-such-dir" sh -c "$probe" | tail -c 1 | last_byte)" '\n'
check "and an empty answer is shown as unknown, never as the last good state" \
  "$(printf '%s' "$probe_out" | pill)" "LLM ?${T}muted"

section "what the pill makes of reports that are not what it expects"
check "garbage" "$(printf 'not json' | pill)" "LLM ?${T}muted"
check "nothing at all" "$(printf '' | pill)" "LLM ?${T}muted"
check "JSON that is not an object" "$(printf '[1,2]' | pill)" "LLM ?${T}muted"
check "null" "$(printf 'null' | pill)" "LLM ?${T}muted"
check "an object without a default block" "$(printf '{"providers":[]}' | pill)" "LLM ?${T}muted"
check "a default block that is not an object" "$(printf '{"default":"x"}' | pill)" "LLM ?${T}muted"
check "a default that is set, not usable and carries no blockers" \
  "$(printf '{"default":{"id":"x","usable":false}}' | pill)" "LLM x · blocked${T}warn"
check "a blocker nobody taught it is shown as blocked, not hidden" \
  "$(printf '{"default":{"id":"x","usable":false,"blockers":["something new"]}}' | pill)" "LLM x · blocked${T}warn"
check "'usable' without being true is not usable" \
  "$(printf '{"default":{"id":"x","usable":"yes"}}' | pill)" "LLM x · blocked${T}warn"
check "usable but carrying a problem is not good news" \
  "$(printf '{"default":{"id":"x","usable":true,"problem":"p","blockers":[]}}' | pill)" "LLM x · blocked${T}warn"
check "an id from a manifest cannot put markup or control characters on screen" \
  "$(printf '{"default":{"id":"a b<c>\\u001b[31m","usable":true}}' | pill)" "LLM a_b_c___31m${T}good"
check "and a long one is cut to what the bar has room for" \
  "$(printf '{"default":{"id":"%s","usable":true}}' "$(printf 'x%.0s' {1..40})" | pill)" "LLM $(printf 'x%.0s' {1..23})…${T}good"

printf '\n'
if ((failures > 0)); then
  printf 'bar-provider-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nbar-provider-test: PASS\n' "$checks" "$checks"
