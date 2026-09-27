#!/usr/bin/env bash
# Tests the launcher's external-agent governance: the agent's tools are wired to
# the governed recon server, and its model egress is fail-closed.
#
# The launcher used to start an agent and say nothing about where that agent's
# model traffic went. It went to the provider, directly, outside the egress gate
# that `shinobi llm` routes through -- so the one component of this system whose
# behaviour most needs saying out loud was the one that said nothing. And the
# agent got no Shinobi tools at all, because nothing had ever offered it the
# server; `install.sh` told the operator to register one by hand and left it
# there.
#
# These checks pin the two halves of the fix: the wiring uses the same
# resolution `shinobi llm` uses (one server, not two), and the launch stops
# unless somebody accepts that the model's own traffic is not governed.
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

# A fake install, so the launcher resolves its siblings the way it does on a
# packaged system, and a fake vendor CLI that records what it was asked to do
# instead of editing a real ~/.claude.json.
mkdir -p "$work/bin" "$work/engagements" "$work/data" "$work/state" "$work/config" "$work/libexec"
cp "$ROOT"/bin/shinobi-{agent,mcp,engagement,default-agent} "$work/bin/"
cp "$ROOT/bin/_shinobi-common.sh" "$work/bin/"
cp -r "$ROOT/libexec/shinobi" "$work/libexec/shinobi"
# The recon server resolves out of the source tree in a checkout, so the tree
# has to be here too or every wiring case fails on resolution, not on wiring.
cp -r "$ROOT/mcp-servers" "$work/mcp-servers"

cat >"$work/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$FAKE_LOG"
case "$1 $2" in
  "mcp get")
    # An absent server is a non-zero exit; that is how the launcher learns a
    # repeat launch has nothing left to do.
    [[ "${FAKE_GET_RC:-1}" == 0 ]] && exit 0
    exit 1
    ;;
  "mcp add")
    printf '%s\n' "$@" >"$FAKE_ADD"
    exit "${FAKE_ADD_RC:-0}"
    ;;
esac
exit 0
FAKE
cp "$work/bin/claude" "$work/bin/codex"
chmod +x "$work/bin/claude" "$work/bin/codex"

cat >"$work/bin/otheragent" <<'FAKE'
#!/usr/bin/env bash
printf 'otheragent %s\n' "$*" >>"$FAKE_LOG"
exit 0
FAKE
chmod +x "$work/bin/otheragent"

export PATH="$work/bin:$PATH"
export XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state" XDG_CONFIG_HOME="$work/config"
export FAKE_LOG="$work/vendor.log" FAKE_ADD="$work/add.txt"
unset SHINOBI_ENGAGEMENTS_DIR SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR
unset SHINOBI_ACCEPT_UNGOVERNED_EGRESS SHINOBI_AGENT_CMD

runs_dir="$work/state/shinobi/agent-runs"
records() { cat "$runs_dir"/*.json 2>/dev/null; }
field() { records | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" 2>/dev/null || true; }
reset() { rm -f "$FAKE_LOG" "$FAKE_ADD"; rm -rf "$runs_dir"; }
# Every launch goes through one of these two. `status` exists because most of
# what this file asserts is an exit code, and a bare failing command under
# `set -e` would end the suite on the first refusal it provoked -- which is the
# refusal the suite exists to provoke.
launch() { SHINOBI_AGENT_CMD="$1" "$work/bin/shinobi-agent" "${@:2}" >"$work/out.txt" 2>"$work/err.txt"; }
status() { launch "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
# Presence, not a count: the refusal names the flag more than once, and how many
# times is not the property under test. The `--` matters -- these patterns start
# with a dash, which grep would otherwise read as its own options.
said() { grep -qF -- "$2" "$work/err.txt" && echo yes || echo no; }
counted() { grep -cF -- "$2" "$work/err.txt" || true; }

"$work/bin/shinobi-engagement" new acme --operator tester >/dev/null
printf 'window:\n  start: "2020-01-01"\n  end: "2030-01-01"\ntargets: ["127.0.0.1"]\n' \
  >"$work/engagements/acme/scope.yaml"
chmod 600 "$work/engagements/acme/scope.yaml"

echo "== a launch without acknowledgement is refused, and changes nothing =="
reset
rc="$(status claude)"
check "refused" "$rc" "1"
check "no run record" "$(records | wc -l)" "0"
check "the agent's own config was not touched" "$([[ -f $FAKE_ADD ]] && echo yes || echo no)" "no"
check "the agent was never launched" "$([[ -f $FAKE_LOG ]] && echo yes || echo no)" "no"
check "the refusal names the flag" "$(said x --accept-ungoverned-egress)" "yes"
check "the refusal says the gate does not cover it" "$(said x 'cannot intercept')" "yes"
check "the refusal still offers governed tools" "$(said x shinobi-recon)" "yes"

echo "== an ungoverned launch is recorded as one =="
reset
rc="$(status claude --accept-ungoverned-egress)"
check "launched once acknowledged" "$rc" "0"
check "record marks the egress ungoverned" "$(field egress)" "ungoverned"
check "record marks it acknowledged" "$(field egress_acknowledged)" "True"
check "record names where the acknowledgement came from" "$(field egress_ack_source)" "flag"
check "record names the server" "$(field mcp_server)" "shinobi-recon"
check "the run record is valid JSON" \
  "$(records | python3 -c 'import json,sys; json.load(sys.stdin); print("yes")' 2>&1)" "yes"

reset
check "the session environment can acknowledge instead" "$(SHINOBI_ACCEPT_UNGOVERNED_EGRESS=1 status claude)" "0"
check "the record says the env var, not the flag" "$(field egress_ack_source)" "env"
reset
check "a value that is not 1 is not an acknowledgement" \
  "$(SHINOBI_ACCEPT_UNGOVERNED_EGRESS=yes status claude)" "1"

echo "== a known agent is offered the server the native client resolves =="
reset
launch claude --accept-ungoverned-egress >/dev/null
check "recorded as registered" "$(field mcp_status)" "registered"
add_argv() { python3 -c 'import sys; print("\n".join(open(sys.argv[1]).read().splitlines()))' "$FAKE_ADD"; }
check "the vendor CLI was asked to add it" "$(add_argv | sed -n 1p)" "mcp"
check "with the agent's own add subcommand" "$(add_argv | sed -n 2p)" "add"
check "into the user's own scope" \
  "$(add_argv | sed -n '3,4p' | tr '\n' ' ' | sed 's/ $//')" "--scope user"
check "under the server's name" "$(add_argv | sed -n '/^shinobi-recon$/p')" "shinobi-recon"
check "the server's own arguments follow a --" "$(add_argv | grep -c '^--$')" "1"

# The point of resolving through llm/mcp.py rather than a second guess in the
# launcher: an agent wired to a *different* recon server than the native client
# would leave two servers with one name and the same tools, one of which answers.
resolved="$("$work/bin/shinobi-mcp" resolve | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["argv"]))')"
registered_tail="$(add_argv | awk '/^--$/{f=1;next} f' | tr '\n' ' ' | sed 's/ $//')"
check "the registered command is the one shinobi llm resolves" "$registered_tail" "$resolved"
registered_env="$(add_argv | awk '/^--env$/{getline; sub(/^PYTHONPATH=/, ""); print; exit}')"
resolved_env="$("$work/bin/shinobi-mcp" resolve | python3 -c 'import json,sys; print(json.load(sys.stdin)["env"].get("PYTHONPATH",""))')"
check "and it carries that resolution's environment" "$registered_env" "$resolved_env"

reset
launch codex --accept-ungoverned-egress >/dev/null
codex_argv="$(add_argv | tr '\n' ' ')"
# Whether the server resolves to an installed entry point or to the source tree
# decides how many options there are, so the property is the one both shapes
# share: the name is the last thing before the `--`, and nothing follows it but
# the command. An option after the name would be the command's to swallow.
check "the server name is the last argument before the --" \
  "$(add_argv | awk '/^--$/{print prev; exit} {prev=$0}')" "shinobi-recon"
name_line="$(add_argv | grep -n '^shinobi-recon$' | cut -d: -f1)"
dash_line="$(add_argv | grep -n '^--$' | cut -d: -f1)"
check "the -- follows the name immediately" "$dash_line" "$((name_line + 1))"
check "codex gets its own add subcommand" "$(add_argv | sed -n '1,2p' | tr '\n' ' ' | sed 's/ $//')" "mcp add"
check "codex is not given claude's --scope" "$(grep -c -- '--scope' "$FAKE_ADD" || true)" "0"
# The server's own command is *meant* to carry flags after the -- (the source-tree
# fallback is `python3 -c ...`), which is why the -- is there. The hazard is the
# other direction: a codex option written after the name would be swallowed by the
# trailing var arg and passed to the server as an argument. So every line before
# the name has to be one of codex's own.
check "every line before the name is a codex option, not a stray flag" \
  "$(add_argv | head -n "$((name_line - 1))" | grep -cvE '^(mcp|add|--env|PYTHONPATH=.*)$' || true)" "0"

echo "== a repeat launch does not register the same server twice =="
reset
launch claude --accept-ungoverned-egress >/dev/null
first_add="$(cat "$FAKE_ADD")"
rm -f "$runs_dir"/*.json
FAKE_GET_RC=0 launch claude --accept-ungoverned-egress >/dev/null
check "an existing registration is left alone" "$(field mcp_status)" "already-registered"
check "and the add was not re-issued" "$(grep -c 'mcp add' "$FAKE_LOG" || true)" "1"
check "the first registration is untouched" "$(cat "$FAKE_ADD")" "$first_add"

echo "== a vendor that refuses the registration stops the launch =="
reset
check "refused" "$(FAKE_ADD_RC=3 status claude --accept-ungoverned-egress)" "1"
check "nothing is recorded for a launch that did not happen" "$(records | wc -l)" "0"
check "the agent was not launched anyway" "$([[ -f $FAKE_LOG ]] && echo yes || echo no)" "yes"
check "the reason is shown" "$(said x 'refused to register')" "yes"
check "and the way out is named" "$(said x 'no-wire-mcp')" "yes"

echo "== an agent that cannot be wired is launched, but only loudly =="
reset
check "launched" "$(status otheragent --accept-ungoverned-egress)" "0"
check "recorded as unwired" "$(field mcp_status)" "unsupported"
check "warned on stderr" "$(said x 'no known way to register')" "yes"
check "told it has no Shinobi tools" "$(said x 'no Shinobi tools')" "yes"
check "the unsupported agent was actually launched" \
  "$(grep -c '^otheragent' "$FAKE_LOG" || true)" "1"

echo "== --no-wire-mcp leaves the agent's configuration alone =="
reset
check "launched" "$(status claude --accept-ungoverned-egress --no-wire-mcp)" "0"
check "recorded as the operator's own wiring" "$(field mcp_status)" "operator-wired"
check "the vendor CLI was never invoked for registration" \
  "$(grep -c 'mcp add' "$FAKE_LOG" || true)" "0"
reset
check "the egress acknowledgement is still required without wiring" \
  "$(status claude --no-wire-mcp)" "1"

echo "== the agent is told what it is running under =="
reset
cat >"$work/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$SHINOBI_AGENT_EGRESS|$SHINOBI_AGENT_MCP_STATUS" >"$FAKE_LOG"
exit 0
FAKE
chmod +x "$work/bin/claude"
status claude --accept-ungoverned-egress --no-wire-mcp >/dev/null
check "the agent's own environment says the egress is ungoverned" \
  "$(cat "$FAKE_LOG")" "ungoverned|operator-wired"

echo "== a run record stays valid JSON when the agent command is hostile =="
# The agent command is operator-supplied and was interpolated into the run record
# as JSON between quotes. A quote or a backslash in it produced a file that no
# parser would read, which is precisely the record whose whole job is to be read
# after the fact.
reset
hostile='q"uote\slash'
cat >"$work/bin/$hostile" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$work/bin/$hostile"
status "$hostile" --accept-ungoverned-egress --no-wire-mcp >/dev/null
check "the record parses" \
  "$(records | python3 -c 'import json,sys; print(json.load(sys.stdin)["agent"])' 2>&1)" "$hostile"

echo "== the arguments the launcher accepts =="
reset
for bad in --nope --accept-ungoverned-egress=1 --wire-mcp; do
  check "'$bad' is refused" "$(status claude "$bad")" "1"
done
"$work/bin/shinobi-agent" --help >"$work/help.txt" 2>&1
check "the help documents the acknowledgement" \
  "$(grep -c 'accept-ungoverned-egress' "$work/help.txt" || true)" "2"
check "the help documents the wiring opt-out" "$(grep -c 'no-wire-mcp' "$work/help.txt" || true)" "2"

echo
if ((failures > 0)); then
  printf 'agent-egress-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nagent-egress-test: PASS\n' "$checks" "$checks"
