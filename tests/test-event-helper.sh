#!/usr/bin/env bash
# Tests that shinobi_emit_event hands `shinobi-event` the payload it was given,
# unchanged.
#
# The helper built its default with "${2:-{}}". Bash ends that expansion at the
# first }, so it is a default of "{" followed by a literal "}": an absent payload
# came out as {} by accident, and every payload that was supplied came out with a
# stray } on the end. shinobi-event parses its payload as JSON and rejected all
# of them, and the helper discards that error on purpose -- a missing event must
# not break the command that emitted it -- so engagement.created,
# engagement.changed, agent.started and the package, update and snapshot events
# were never published, and nothing said so. Every caller supplies a payload, so
# the one case that worked was the one none of them used.
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

# A stand-in for shinobi-event that records the arguments it was called with, one
# per line. The helper is a thin wrapper, so what it passes on is the whole of
# its behaviour; whether the real command accepts that is checked further down.
mkdir -p "$work/stub" "$work/empty"
cat >"$work/stub/shinobi-event" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SHINOBI_TEST_ARGV"
exit "${SHINOBI_TEST_RC:-0}"
STUB
chmod +x "$work/stub/shinobi-event"
export SHINOBI_TEST_ARGV="$work/argv.txt"

# shellcheck disable=SC1091
source "$ROOT/bin/_shinobi-common.sh"

# What shinobi-event was called with, as publish|<event>|<payload>.
emitted() {
  rm -f "$SHINOBI_TEST_ARGV"
  (PATH="$work/stub:$PATH"; shinobi_emit_event "$@")
  if [[ -f "$SHINOBI_TEST_ARGV" ]]; then
    paste -sd'|' "$SHINOBI_TEST_ARGV"
  else
    echo '(shinobi-event was not called)'
  fi
}

echo "== a payload reaches shinobi-event as it was given =="
check "a flat object" \
  "$(emitted engagement.created '{"engagement":"acme"}')" \
  'publish|engagement.created|{"engagement":"acme"}'
check "a nested object keeps its closing braces" \
  "$(emitted a.b '{"a":{"b":1}}')" \
  'publish|a.b|{"a":{"b":1}}'
check "a brace inside a string is left alone" \
  "$(emitted a.b '{"note":"a}b"}')" \
  'publish|a.b|{"note":"a}b"}'

echo "== no payload means an empty object =="
check "an absent payload" "$(emitted a.b)" 'publish|a.b|{}'
check "an empty payload" "$(emitted a.b '')" 'publish|a.b|{}'

echo "== the helper never fails the command that called it =="
rc=0
(PATH="$work/empty"; shinobi_emit_event a.b '{}') || rc=$?
check "no shinobi-event on PATH is not an error" "$rc" "0"
rc=0
(PATH="$work/stub:$PATH"; SHINOBI_TEST_RC=1 shinobi_emit_event a.b '{}') || rc=$?
check "a shinobi-event that fails is not an error" "$rc" "0"

echo "== the real shinobi-event accepts what a real caller sends =="
# Through the actual path that never worked: shinobi-engagement publishes
# engagement.created with a payload, shinobi-event parses it as JSON, and the
# event has to be on the bus afterwards. Nothing is stubbed, and the runtime
# directory is this test's own so nothing lands in the operator's.
mkdir -p "$work/state" "$work/engagements"
published="$(
  export PATH="$ROOT/bin:$PATH" XDG_RUNTIME_DIR="$work/run" XDG_STATE_HOME="$work/state" \
    SHINOBI_ENGAGEMENTS_DIR="$work/engagements"
  unset SHINOBI_STATE_FILE
  "$ROOT/bin/shinobi-engagement" new acme >/dev/null
  "$ROOT/bin/shinobi-event" recent | python3 -c '
import json, sys
events = json.load(sys.stdin)
print(len(events), " ".join("%s %s" % (e["event"], json.dumps(e["payload"], sort_keys=True)) for e in events))
' 2>&1 || true
)"
check "creating an engagement publishes engagement.created, with its payload" \
  "$published" '1 engagement.created {"engagement": "acme"}'

echo
if ((failures > 0)); then
  printf 'event-helper-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nevent-helper-test: PASS\n' "$checks" "$checks"
