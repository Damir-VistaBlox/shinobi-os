#!/usr/bin/env bash
# Tests that the launcher, the engagement CLI and the MCP scope gate agree on
# which directory engagements live in.
#
# The scope gate stopped trusting a caller-supplied per-engagement path and
# now resolves an engagement by name under an engagements *root*. The launcher
# kept exporting the old per-engagement variable, so on a packaged install --
# where the root is the install sibling rather than the XDG default -- the
# agent it launched could not find the very engagement it was launched for.
# Nothing caught it, because every test set the root by hand.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# A fake install: shinobi's commands beside an engagements/ sibling, which is
# the layout that breaks when the launcher exports the wrong variable.
mkdir -p "$work/bin" "$work/engagements" "$work/data" "$work/state" "$work/config"
for cmd in shinobi-agent shinobi-engagement _shinobi-common.sh; do
  cp "$ROOT/bin/$cmd" "$work/bin/$cmd"
done
cp -r "$ROOT/libexec/shinobi" "$work/libexec-shinobi"
mkdir -p "$work/libexec"
rm -rf "$work/libexec-shinobi"
cp -r "$ROOT/libexec/shinobi" "$work/libexec/shinobi"

export XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state"
export XDG_CONFIG_HOME="$work/config"
unset SHINOBI_ENGAGEMENTS_DIR SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR

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

echo "== the CLI resolves the install sibling, not the XDG default =="
resolved="$("$work/bin/shinobi-engagement" list 2>&1 >/dev/null; bash -c "source '$work/bin/_shinobi-common.sh'; shinobi_engagements_dir")"
check "shinobi_engagements_dir prefers the ../engagements sibling" "$resolved" "$work/engagements"

"$work/bin/shinobi-engagement" new acme --operator tester >/dev/null
check "engagement is created under the sibling root" "$([[ -d $work/engagements/acme ]] && echo yes || echo no)" "yes"
check "nothing is created in the XDG data directory" "$([[ -e $work/data/shinobi/engagements ]] && echo yes || echo no)" "no"

printf 'window:\n  start: "2020-01-01"\n  end: "2030-01-01"\ntargets: ["127.0.0.1"]\n' > "$work/engagements/acme/scope.yaml"
chmod 600 "$work/engagements/acme/scope.yaml"

echo "== the launcher exports the root the scope gate reads =="
# Run the real launcher and capture the environment it hands the agent, by
# pointing it at /usr/bin/env. Reconstructing the variables here instead would
# test this script's own idea of the launcher rather than the launcher.
SHINOBI_AGENT_CMD=/usr/bin/env "$work/bin/shinobi-agent" > "$work/agent-env.txt" 2>/dev/null
launcher_env="$(grep -E '^SHINOBI_(ENGAGEMENT|ENGAGEMENTS_DIR)=' "$work/agent-env.txt" || true)"
check "launcher exports SHINOBI_ENGAGEMENT" "$(sed -n 's/^SHINOBI_ENGAGEMENT=//p' <<<"$launcher_env")" "acme"
check "launcher exports the engagements root" "$(sed -n 's/^SHINOBI_ENGAGEMENTS_DIR=//p' <<<"$launcher_env")" "$work/engagements"
check "the launched agent's environment has no per-engagement path" \
  "$(grep -c '^SHINOBI_ENGAGEMENT_DIR=' "$work/agent-env.txt" || true)" "0"

echo "== the scope gate resolves an engagement from that env alone =="
# Exactly the variables the launcher exports: no XDG_DATA_HOME pointing at the
# engagements, nothing else hand-set.
resolved_engagement="$(
  env -i PATH="$PATH" HOME="$HOME" $(tr '\n' ' ' <<<"$launcher_env") \
    python3 -c "
import sys
sys.path.insert(0, '$ROOT/mcp-servers/shinobi-recon')
from shinobi_recon.scope import current_engagement
print(current_engagement().dir)
" 2>&1
)"
check "scope gate finds the engagement from the launcher's env" "$resolved_engagement" "$work/engagements/acme"

echo "== a hostile per-engagement variable cannot redirect the gate =="
hostile="$(
  env -i PATH="$PATH" HOME="$HOME" \
    SHINOBI_ENGAGEMENT=acme SHINOBI_ENGAGEMENTS_DIR="$work/engagements" \
    SHINOBI_ENGAGEMENT_DIR="$work/evil" \
    python3 -c "
import sys
sys.path.insert(0, '$ROOT/mcp-servers/shinobi-recon')
from shinobi_recon.scope import current_engagement
print(current_engagement().dir)
" 2>&1
)"
check "the gate ignores the attacker-supplied directory" "$hostile" "$work/engagements/acme"

echo
if (( failures > 0 )); then
  printf 'launcher-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nlauncher-test: PASS\n' "$checks" "$checks"
