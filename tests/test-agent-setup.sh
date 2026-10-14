#!/usr/bin/env bash
# Tests `shinobi agent install | login | setup | registry`: the guide-only set-up
# of vendor agent CLIs (Claude Code, Codex).
#
# What is under test is the edge between an operator and somebody else's code. The
# command is allowed to run a vendor installer and a vendor login, and only
# because it shows exactly what it will run, waits for a yes at the operator's own
# terminal, records that it is about to, and keeps what the vendor prints on that
# terminal. So the cases that matter are refusals: nothing runs with no terminal,
# nothing runs on a piped "yes", nothing runs when the audit record cannot be
# written, nothing runs for an id that is not in the table, and the answer to
# "did it work" is never read out of a vendor's credential files.
#
# NOTHING HERE MAY REACH REAL VENDOR CODE. This machine very likely has a real
# `claude`, `codex` and `curl`, and a test that ran the real installer or login
# would be doing the very thing the command exists to put a person in front of. So
# every command runs with a PATH made of a directory of links to a few system
# tools plus a directory of fakes, HOME is this test's own (so ~/.local/bin is
# too), and the fake `curl` fails loudly for any URL it was not written for. A
# case that finds the real thing on PATH fails before it runs anything.
#
# The prompts are answered through a pseudo-terminal (tests/pty-drive.py), because
# the command reads its answers from /dev/tty and not from stdin, which a pipe
# cannot exercise.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
umask 022

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

PY="$(command -v python3)"
SETSID="$(command -v setsid || true)"
if [[ -z "$SETSID" ]]; then
  echo "agent-setup-test: SKIP (setsid, from util-linux, is needed to run a command with no terminal)"
  exit 0
fi

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

# --- the sandbox ------------------------------------------------------------
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
  XDG_RUNTIME_DIR="$work/run" TMPDIR="$work/tmp" LC_ALL=C \
  SHINOBI_ENGAGEMENTS_DIR="$work/engagements"
unset SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR SHINOBI_AUDIT_FILE SHINOBI_BIN_DIR \
  SHINOBI_ACCEPT_UNGOVERNED_EGRESS SHINOBI_AGENT_CMD
FAKE_LOG="$work/fakelog"
export FAKE_LOG
tools="$work/tools"
fake="$work/fake"
mkdir -p "$tools" "$fake" "$FAKE_LOG" "$work/proj/.claude"
: >"$work/proj/.mcp.json"

# A few system tools and nothing else. In particular no curl, claude or codex.
for tool in bash sh env readlink dirname basename mktemp cat head tail sed awk tr wc grep date id rm ls \
  sleep mkdir chmod cp mv ln find sort uniq cut tee touch test stat realpath uname whoami pwd yes true false; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -n "$src" && "$src" == /* ]]; then ln -sf "$src" "$tools/$tool"; fi
done
ln -sf "$PY" "$tools/python3"
SANDBOX_PATH="$fake:$tools"

cat >"$fake/curl" <<'EOF'
#!/usr/bin/env bash
# The only curl the commands under test can reach. It serves the two documented
# installers, as harmless scripts, and refuses every other request.
printf '%s\n' "$*" >>"$FAKE_LOG/curl.args"
[[ "${FAKE_CURL_FAIL:-}" == 1 ]] && exit 22
case "$*" in
  *"https://claude.ai/install.sh"*) name=claude ;;
  *"https://chatgpt.com/codex/install.sh"*) name=codex ;;
  *) echo "fake curl: not a request this test expects" >&2; exit 22 ;;
esac
cat <<SCRIPT
echo "fake $name installer ran"
pwd >"$FAKE_LOG/installer.cwd"
SCRIPT
if [[ "${FAKE_NO_BINARY:-}" != 1 ]]; then
  dest="${FAKE_INSTALL_DIR:-$HOME/.local/bin}"
  cat <<SCRIPT
mkdir -p "$dest"
cp "$FAKE_LOG/vendor-$name" "$dest/$name"
chmod +x "$dest/$name"
SCRIPT
fi
# An installer that did its work and then failed, to tell "the exit status said
# so" from "no binary turned up".
if [[ -n "${FAKE_INSTALLER_EXIT:-}" ]]; then echo "exit $FAKE_INSTALLER_EXIT"; fi
EOF
cat >"$FAKE_LOG/vendor-claude" <<'EOF'
#!/usr/bin/env bash
# Measured before any redirection, or `-t 1` would be asking about the log file.
if [[ -t 0 ]]; then in=tty; else in=notty; fi
if [[ -t 1 ]]; then outk=tty; else outk=notty; fi
{
  echo "args=$*"
  echo "cwd=$(pwd)"
  echo "stdin=$in"
  echo "stdout=$outk"
  echo "entries=$(ls -A | tr '\n' ' ')"
} >>"$FAKE_LOG/claude.runs"
echo "fake claude: Login successful"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
cat >"$FAKE_LOG/vendor-codex" <<'EOF'
#!/usr/bin/env bash
echo "args=$* cwd=$(pwd)" >>"$FAKE_LOG/codex.runs"
case "$*" in
  "login status") echo "fake codex: Logged in using ChatGPT"; exit "${FAKE_CODEX_STATUS_RC:-0}" ;;
  "login") echo "fake codex: browser flow"; exit "${FAKE_CODEX_LOGIN_RC:-0}" ;;
esac
exit 3
EOF
chmod +x "$fake/curl" "$FAKE_LOG/vendor-claude" "$FAKE_LOG/vendor-codex"

AGENT="$ROOT/bin/shinobi-agent"
audit="$XDG_STATE_HOME/shinobi/audit.jsonl"
events="$XDG_RUNTIME_DIR/shinobi/events.jsonl"
default_file="$HOME/.config/shinobi/default-agent"

# reset: a clean world for the next case.
reset() {
  rm -f "$fake/claude" "$fake/codex"
  rm -rf "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" "$FAKE_LOG"/*.args \
    "$FAKE_LOG"/*.runs "$FAKE_LOG"/*.cwd
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME/shinobi" "$XDG_RUNTIME_DIR" "$TMPDIR"
  unset FAKE_CURL_FAIL FAKE_NO_BINARY FAKE_INSTALLER_EXIT FAKE_INSTALL_DIR FAKE_CLAUDE_RC FAKE_CODEX_STATUS_RC FAKE_CODEX_LOGIN_RC \
    SHINOBI_ACCEPT_UNGOVERNED_EGRESS
}
# place <name> [dir]: put a fake vendor binary where the installer would.
place() {
  local dest="${2:-$HOME/.local/bin}"
  mkdir -p "$dest"
  cp "$FAKE_LOG/vendor-$1" "$dest/$1"
  chmod +x "$dest/$1"
}

# steps <regex> <answer> ...: the JSON script for the pty driver.
steps() { "$PY" -c 'import json,sys; a=sys.argv[1:]; print(json.dumps([[a[i], a[i+1]] for i in range(0, len(a), 2)]))' "$@"; }
ACK='continue\? \[y/N\]'
CONFIRM='Run it now\? \[y/N\]'
DEFAULT_Q="your default agent for 'shinobi agent'\? \[Y/n\]"

# pty <script-json> <cmd...>: run on a terminal, answering from the script.
rc=0
transcript=""
pty() {
  local script="$1"
  shift
  rc=0
  PTY_SCRIPT="$script" PTY_OUT="$work/transcript" PTY_TIMEOUT=12 PATH="$SANDBOX_PATH" \
    "$PY" "$ROOT/tests/pty-drive.py" -- "$@" || rc=$?
  transcript="$(<"$work/transcript")"
}
# notty <cmd...>: run with no controlling terminal at all.
out=""
err=""
notty() {
  rc=0
  out="$("$SETSID" -w env PATH="$SANDBOX_PATH" "$@" 2>"$work/err" </dev/null)" || rc=$?
  err="$(<"$work/err")"
}

calls() { if [[ -e "$FAKE_LOG/$1" ]]; then wc -l <"$FAKE_LOG/$1"; else echo 0; fi; }
# audit_seq <capability>: the statuses recorded, in order.
audit_seq() {
  "$PY" - "$1" <<'EOF'
import json, os, sys
try:
    rows = [json.loads(l) for l in open(os.environ["XDG_STATE_HOME"] + "/shinobi/audit.jsonl")]
except OSError:
    rows = []
print(",".join(r["status"] for r in rows if r["capability"] == sys.argv[1]) or "-")
EOF
}
# audit_ack_ok <capability> <agent> <ack>: whether every record of it hashes the
# arguments {"agent": ..., "ack": ...}, so the acknowledgement source is the one recorded.
audit_ack_ok() {
  "$PY" - "$1" "$2" "$3" <<'EOF'
import hashlib, json, os, sys
cap, agent, ack = sys.argv[1:4]
want = hashlib.sha256(json.dumps({"agent": agent, "ack": ack}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
try:
    rows = [json.loads(l) for l in open(os.environ["XDG_STATE_HOME"] + "/shinobi/audit.jsonl")]
except OSError:
    rows = []
mine = [r for r in rows if r["capability"] == cap]
print("yes" if mine and all(r["arguments_hash"] == want for r in mine) else "no")
EOF
}
audit_details() {
  "$PY" - "$1" <<'EOF'
import json, os, sys
try:
    rows = [json.loads(l) for l in open(os.environ["XDG_STATE_HOME"] + "/shinobi/audit.jsonl")]
except OSError:
    rows = []
print(" | ".join(r["detail"] for r in rows if r["capability"] == sys.argv[1]))
EOF
}
event_count() {
  if [[ -e "$events" ]]; then grep -c "\"event\": \"$1\"" "$events" || true; else echo 0; fi
}

reset

echo "== the sandbox cannot reach real vendor code =="
check "PATH holds no curl but the fake" "$(PATH="$SANDBOX_PATH" command -v curl)" "$fake/curl"
check "PATH holds no claude" "$(PATH="$SANDBOX_PATH" command -v claude || echo none)" "none"
check "PATH holds no codex" "$(PATH="$SANDBOX_PATH" command -v codex || echo none)" "none"
check "the fake curl refuses a URL it was not written for" \
  "$(PATH="$SANDBOX_PATH" curl -fsSL https://example.invalid/x.sh >/dev/null 2>&1; echo $?)" "22"
rm -f "$FAKE_LOG/curl.args"

echo "== the table is fixed, checked and honest =="
check "it names exactly the agents whose CLI can be given an MCP server" \
  "$(PYTHONPATH=libexec/shinobi "$PY" -c 'from shinobi_control import agentreg, mcpctl; print(agentreg.ids() == list(mcpctl.KNOWN_AGENTS))')" "True"
check "every entry's egress is ungoverned, as a constant and not a field" \
  "$(PYTHONPATH=libexec/shinobi "$PY" -c 'from shinobi_control import agentreg; print(agentreg.EGRESS, any(hasattr(a, "egress") for a in agentreg.AGENTS))')" "ungoverned False"
check "every install command is the vendor's pipeline, from a documented host" \
  "$(PYTHONPATH=libexec/shinobi "$PY" -c '
from shinobi_control import agentreg
ok = all(a.install_text.startswith("curl -fsSL https://") and a.install_text.split("/")[2] in a.install_hosts
         and a.install_text.endswith(("| bash", "| sh")) for a in agentreg.AGENTS)
print(ok)')" "True"
check "every entry says where its commands were read, and when" \
  "$(PYTHONPATH=libexec/shinobi "$PY" -c 'from shinobi_control import agentreg; print(all(a.docs and a.verified.startswith("20") for a in agentreg.AGENTS))')" "True"
check "the table is not a provider manifest" "$(ls providers | grep -cE '^(claude|codex)\.toml$' || true)" "0"
check "an unknown id is an error that does not repeat it" \
  "$(PYTHONPATH=libexec/shinobi "$PY" -c '
from shinobi_control import agentreg
try:
    agentreg.get("MARKER-prompt text")
except agentreg.AgentError as e:
    print("MARKER" in str(e))')" "False"
check "the code never names a vendor's credential or settings files" \
  "$(grep -hE '(^|[^a-z.])\.claude|\.codex|\.credentials|auth\.json|CLAUDE_CONFIG_DIR|CODEX_HOME' \
      libexec/shinobi/shinobi_control/agentsetup.py libexec/shinobi/shinobi_control/agentreg.py | wc -l)" "0"

echo "== registry =="
reset
notty "$AGENT" registry --json
check "it needs no terminal and no engagement" "$rc" "0"
check "both agents are listed, in the table's order" "$(jq -r '[.agents[].id] | join(",")' <<<"$out")" "claude,codex"
check "neither is installed in this sandbox" "$(jq -r '[.agents[].installed] | join(",")' <<<"$out")" "false,false"
check "both say their egress is ungoverned" "$(jq -r '[.agents[].egress] | unique | join(",")' <<<"$out")" "ungoverned"
check "both can be given the governed MCP server" "$(jq -r '[.agents[].mcp] | join(",")' <<<"$out")" "true,true"
check "the install command is shown as the vendor's" "$(jq -r '.agents[0].install_command' <<<"$out")" "curl -fsSL https://claude.ai/install.sh | bash"
check "Shinobi says it cannot know a Claude Code login, and can ask Codex" \
  "$(jq -r '[.agents[].login_state] | join(",")' <<<"$out")" "not known,ask the vendor CLI"
place claude
place codex "$fake"
mkdir -p "$HOME/.config/shinobi"
printf 'codex\n' >"$default_file"
notty "$AGENT" registry --json
check "an agent found off PATH is reported as such" \
  "$(jq -r '.agents[0] | "\(.installed) \(.on_path) \(.path)"' <<<"$out")" "true false $HOME/.local/bin/claude"
check "an agent found on PATH is reported as such" "$(jq -r '.agents[1] | "\(.installed) \(.on_path)"' <<<"$out")" "true true"
check "the default agent is marked" "$(jq -r '[.agents[].default] | join(",")' <<<"$out")" "false,true"
notty "$AGENT" registry
check "the text form lists them too" "$(contains "$out" 'Claude Code')|$(contains "$out" 'OpenAI Codex CLI')" "yes|yes"
check "and says what each would run" "$(contains "$out" 'curl -fsSL https://chatgpt.com/codex/install.sh | sh')" "yes"

echo "== what is refused before anything runs =="
reset
for argv in "install" "install claude codex" "install --yes claude" "install claude --yes" "login" "setup --no-such-flag claude" "registry claude" "registry --yaml"; do
  notty "$AGENT" $argv
  check "'$argv' is a usage error" "$rc" "2"
done
notty env PYTHONPATH="$ROOT/libexec/shinobi" "$PY" -m shinobi_control.agentsetup frobnicate claude
check "an unknown action is refused by the module" "$rc|$(contains "$err" 'unknown action')" "2|yes"
for action in install login setup; do
  notty "$AGENT" "$action" "MARKER-please review the scope of 10.10.10.5"
  check "$action: a prompt in the id slot is refused" "$rc" "1"
  check "$action: and not repeated back" "$(contains "$out$err" 'MARKER')|$(contains "$out$err" '10.10.10.5')" "no|no"
  check "$action: it lists what is known instead" "$(contains "$err" 'known: claude, codex')" "yes"
done
check "none of that touched the vendor, the audit journal or the network" \
  "$(calls curl.args)|$([[ -e $audit ]] && echo audit || echo none)" "0|none"

notty "$AGENT" install claude
check "install with no terminal refuses" "$rc" "1"
check "and says it needs one" "$(contains "$err" 'needs a terminal')" "yes"
notty env SHINOBI_ACCEPT_UNGOVERNED_EGRESS=1 "$AGENT" install claude --accept-ungoverned-egress
check "even with the acknowledgement given twice over, no terminal means no install" "$rc|$(calls curl.args)" "1|0"
check "nothing was installed" "$([[ -e $HOME/.local/bin/claude ]] && echo present || echo absent)" "absent"
check "and nothing was recorded, since nothing was started" "$(audit_seq agent.install)" "-"

place claude
notty "$AGENT" login claude --accept-ungoverned-egress
check "login with no terminal refuses" "$rc|$(contains "$err" 'needs a terminal')|$(calls claude.runs)" "1|yes|0"
rm -f "$HOME/.local/bin/claude"
notty "$AGENT" login claude --accept-ungoverned-egress
check "login before install says to install first" "$rc|$(contains "$err" 'shinobi agent install claude')" "1|yes"

echo "== installing: the answer comes from the terminal and defaults to no =="
reset
pty "$(steps "$ACK" $'n\n')" "$AGENT" install claude
check "declining the acknowledgement stops there" "$rc" "1"
check "it says what was missing" "$(contains "$transcript" 'not continuing without the acknowledgement')" "yes"
check "and nothing ran" "$(calls curl.args)|$(audit_seq agent.install)" "0|-"

pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'n\n')" "$AGENT" install claude
check "declining the install: refused" "$rc|$(contains "$transcript" 'Nothing was run.')" "1|yes"
check "and nothing ran, and nothing was recorded" "$(calls curl.args)|$(audit_seq agent.install)" "0|-"

pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'\n')" "$AGENT" install claude
check "an empty answer is a no" "$rc|$(calls curl.args)" "1|0"

pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'maybe\n')" "$AGENT" install claude
check "so is anything that is not a clear yes" "$rc|$(calls curl.args)" "1|0"

# `yes |` supplies a "y" to anything that reads stdin. The answer has to come from
# the terminal, where the operator types "n".
pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'n\n')" bash -c 'yes | "$0" install claude' "$AGENT"
check "a piped yes confirms nothing" "$(calls curl.args)|$([[ -e $HOME/.local/bin/claude ]] && echo installed || echo absent)" "0|absent"

pty "$(steps "$CONFIRM" $'n\n')" env SHINOBI_ACCEPT_UNGOVERNED_EGRESS=1 "$AGENT" install claude
check "the session-wide acknowledgement satisfies the acknowledgement" "$(contains "$transcript" 'Do you accept that')" "no"
check "but never the confirmation: the operator still says no" "$rc|$(calls curl.args)" "1|0"

pty "$(steps "$CONFIRM" $'n\n')" "$AGENT" install claude --accept-ungoverned-egress
check "the flag does not skip the confirmation either" "$rc|$(contains "$transcript" 'Run it now?')|$(calls curl.args)" "1|yes|0"

echo "== what the operator is shown before saying yes =="
check "the exact command, on a line of its own" "$(contains "$transcript" '      curl -fsSL https://claude.ai/install.sh | bash')" "yes"
check "where it downloads from" "$(contains "$transcript" 'downloads from claude.ai')" "yes"
check "that Shinobi has not read it" "$(contains "$transcript" 'cannot vouch for it')" "yes"
check "that it runs as them and not as root" "$(contains "$transcript" 'not as root')" "yes"
check "where the vendor documents it, and when that was read" "$(contains "$transcript" 'https://code.claude.com/docs/en/setup (read on 2026-10-14)')" "yes"
check "that the agent's own traffic is outside the egress gate" "$(contains "$transcript" 'NOT governed')" "yes"
pty "$(steps "$CONFIRM" $'n\n')" "$AGENT" install codex --accept-ungoverned-egress
check "codex shows its own command" "$(contains "$transcript" '      curl -fsSL https://chatgpt.com/codex/install.sh | sh')" "yes"
check "and both of its hosts" "$(contains "$transcript" 'chatgpt.com, releases.openai.com')" "yes"

echo "== installing: what happens after a yes =="
reset
pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'y\n')" "$AGENT" install claude
check "installs, and succeeds" "$rc" "0"
check "the vendor's installer was the fake curl, asked for the documented URL" \
  "$(<"$FAKE_LOG/curl.args")" "-fsSL https://claude.ai/install.sh"
check "the binary is where the installer puts it" "$([[ -x $HOME/.local/bin/claude ]] && echo yes || echo no)" "yes"
check "what the vendor printed reached the terminal" "$(contains "$transcript" 'fake claude installer ran')" "yes"
check "it was reported as installed" "$(contains "$transcript" "is installed: $HOME/.local/bin/claude")" "yes"
check "and, being off PATH, with what to do about it" "$(contains "$transcript" 'is not on your PATH')|$(contains "$transcript" 'Shinobi does not edit it')" "yes|yes"
installer_cwd="$(<"$FAKE_LOG/installer.cwd")"
check "the installer ran in a temporary directory of its own" "$(contains "$installer_cwd" "$TMPDIR/shinobi-agent-install-")" "yes"
check "which is gone afterwards" "$([[ -e $installer_cwd ]] && echo present || echo gone)" "gone"
check "intent was recorded first, then the outcome" "$(audit_seq agent.install)" "started,completed"
check "with the acknowledgement source, here the prompt" "$(audit_ack_ok agent.install claude prompt)" "yes"
check "and the exit status and where the binary was found" \
  "$(contains "$(audit_details agent.install)" 'installer exit status 0; binary found off PATH')" "yes"
check "one event announced it" "$(event_count agent.install.finished)" "1"
check "nothing was written to the operator's shell profile" "$(ls -A "$HOME" | grep -cE '^\.(bashrc|zshrc|profile|bash_profile|zprofile)$' || true)" "0"

echo "== installing: where the vendor's output goes =="
reset
pty "$(steps "$CONFIRM" $'y\n')" bash -c '"$0" install claude --accept-ungoverned-egress >"$1" 2>&1' "$AGENT" "$work/captured"
check "the install still works with output redirected" "$rc" "0"
check "the vendor's output is on the terminal" "$(contains "$transcript" 'fake claude installer ran')" "yes"
check "and is not in what was redirected" "$(contains "$(<"$work/captured")" 'fake claude installer ran')" "no"
check "nor is it in the audit journal or the event bus" \
  "$(contains "$(cat "$audit" "$events" 2>/dev/null)" 'installer ran')" "no"

echo "== installing: outcomes that are not success =="
reset
export FAKE_CURL_FAIL=1
pty "$(steps "$CONFIRM" $'y\n')" "$AGENT" install claude --accept-ungoverned-egress
check "a failed download fails the install" "$rc" "1"
check "and says it was the installer that failed, with its exit status" "$(contains "$transcript" 'installer exited with status 22')" "yes"
check "not that it finished without producing a binary" "$(contains "$transcript" 'finished, but')" "no"
check "the outcome is recorded as failed" "$(audit_seq agent.install)" "started,failed"
check "one event, saying it did not work" "$(event_count agent.install.finished)|$(grep -c '"ok": false' "$events")" "1|1"

reset
export FAKE_INSTALLER_EXIT=7
pty "$(steps "$CONFIRM" $'y\n')" "$AGENT" install claude --accept-ungoverned-egress
check "an installer that leaves a binary and exits non-zero has still failed" "$rc" "1"
check "it says what the installer's exit status was" "$(contains "$transcript" 'installer exited with status 7')" "yes"
check "and is recorded as failed, with what was found" \
  "$(audit_seq agent.install)|$(contains "$(audit_details agent.install)" 'installer exit status 7; binary found off PATH')" "started,failed|yes"

reset
export FAKE_NO_BINARY=1
pty "$(steps "$CONFIRM" $'y\n')" "$AGENT" install claude --accept-ungoverned-egress
check "an installer that exits 0 and leaves no binary is not a success" "$rc" "1"
check "it says so" "$(contains "$transcript" 'finished, but claude is not on PATH or in ~/.local/bin')" "yes"
check "and records a failure" "$(audit_seq agent.install)" "started,failed"

reset
export FAKE_INSTALL_DIR="$work/fake"
pty "$(steps "$CONFIRM" $'y\n')" "$AGENT" install claude --accept-ungoverned-egress
check "an install that lands on PATH is reported without the PATH advice" "$rc|$(contains "$transcript" 'is not on your PATH')" "0|no"

reset
place claude "$fake"
notty "$AGENT" install claude
check "already installed: succeeds, with no terminal, with no acknowledgement" "$rc|$(contains "$out" 'already installed')" "0|yes"
check "and runs nothing" "$(calls curl.args)|$(audit_seq agent.install)" "0|-"
rm -f "$fake/claude"

reset
rc=0
PTY_SCRIPT="[]" PTY_OUT="$work/transcript" PTY_TIMEOUT=20 PATH="$tools" "$PY" "$ROOT/tests/pty-drive.py" -- "$AGENT" install claude --accept-ungoverned-egress || rc=$?
transcript="$(<"$work/transcript")"
check "with curl missing it says so, and does not get as far as asking" \
  "$rc|$(contains "$transcript" 'needs curl on PATH')|$(contains "$transcript" 'Run it now')" "1|yes|no"

echo "== no record, no run =="
reset
mkdir -p "$audit"
pty "$(steps "$CONFIRM" $'y\n')" "$AGENT" install claude --accept-ungoverned-egress
check "a journal that cannot be written stops the install" "$rc" "1"
check "it says nothing was run, and why" "$(contains "$transcript" 'nothing was run: the audit journal could not be written')" "yes"
check "the vendor's installer was never reached" "$(calls curl.args)|$([[ -e $HOME/.local/bin/claude ]] && echo installed || echo absent)" "0|absent"
rmdir "$audit"

reset
place claude
mkdir -p "$audit"
pty "[]" "$AGENT" login claude --accept-ungoverned-egress
check "and the same for a login: it is not handed off" "$rc|$(calls claude.runs)|$(contains "$transcript" 'nothing was run')" "1|0|yes"
rmdir "$audit"

echo "== logging in to Claude Code =="
reset
place claude
pty "$(steps "$ACK" $'y\n')" bash -c 'cd "$1" && exec "$0" login claude' "$AGENT" "$work/proj"
check "it succeeds" "$rc" "0"
check "the vendor CLI was started once, with no arguments" "$(calls claude.runs)|$(grep -c '^args=$' "$FAKE_LOG/claude.runs")" "5|1"
check "not in the directory the command was run from" "$(grep '^cwd=' "$FAKE_LOG/claude.runs" | grep -c "$work/proj" || true)" "0"
check "nor in the home directory" "$(grep '^cwd=' "$FAKE_LOG/claude.runs" | grep -cx "cwd=$HOME" || true)" "0"
check "but in an empty temporary directory of its own, so no project settings or server list are in reach" \
  "$(grep '^cwd=' "$FAKE_LOG/claude.runs" | grep -c "cwd=$TMPDIR/shinobi-agent-login-")|$(grep '^entries=' "$FAKE_LOG/claude.runs")" "1|entries="
check "which is gone afterwards" "$(find "$TMPDIR" -mindepth 1 | wc -l)" "0"
check "it had the terminal for input and output" "$(grep -c '^stdin=tty$' "$FAKE_LOG/claude.runs")|$(grep -c '^stdout=tty$' "$FAKE_LOG/claude.runs")" "1|1"
check "the operator was told what this session is, and what to do" \
  "$(contains "$transcript" 'full Claude Code session')|$(contains "$transcript" 'type /exit')|$(contains "$transcript" "Do real work through 'shinobi agent'")" "yes|yes|yes"
check "and that the login is the vendor's" "$(contains "$transcript" 'Shinobi does not see it, store it, or read the files it leaves')" "yes"
check "it does not claim to know the login worked" "$(contains "$transcript" 'no command Shinobi can ask')" "yes"
check "intent first, then the outcome" "$(audit_seq agent.login)" "started,completed"
check "with the acknowledgement source" "$(audit_ack_ok agent.login claude prompt)" "yes"
check "one event" "$(event_count agent.login.finished)" "1"

reset
place claude
export FAKE_CLAUDE_RC=3
pty "[]" "$AGENT" login claude --accept-ungoverned-egress
check "a vendor CLI that exits non-zero is a failed login" "$rc|$(audit_seq agent.login)" "1|started,failed"
unset FAKE_CLAUDE_RC

reset
place claude
pty "$(steps "$ACK" $'n\n')" "$AGENT" login claude
check "declining the acknowledgement: not handed off" "$rc|$(calls claude.runs)|$(audit_seq agent.login)" "1|0|-"
pty "[]" env SHINOBI_ACCEPT_UNGOVERNED_EGRESS=1 "$AGENT" login claude
check "the session-wide acknowledgement is accepted, and recorded as such" "$rc|$(audit_ack_ok agent.login claude env)" "0|yes"
rm -f "$audit"
pty "[]" "$AGENT" login claude --accept-ungoverned-egress
check "and the flag, recorded as the flag" "$rc|$(audit_ack_ok agent.login claude flag)" "0|yes"

echo "== logging in to Codex =="
reset
place codex
pty "[]" "$AGENT" login codex --accept-ungoverned-egress
check "it succeeds" "$rc" "0"
check "codex is asked to log in, and then asked whether that worked" \
  "$(sed 's/ cwd=.*//' "$FAKE_LOG/codex.runs" | paste -sd'|')" "args=login|args=login status"
check "the verdict is the vendor's" "$(contains "$transcript" 'OpenAI Codex CLI: logged in.')" "yes"
check "the outcome records the login state" "$(contains "$(audit_details agent.login)" 'login state: logged in')" "yes"
check "neither command ran where the operator was" "$(grep -c "cwd=$TMPDIR/shinobi-agent-login-" "$FAKE_LOG/codex.runs")" "2"
reset
place codex
export FAKE_CODEX_STATUS_RC=1
pty "[]" "$AGENT" login codex --accept-ungoverned-egress
check "when the vendor says it did not work, so does Shinobi" "$(contains "$transcript" 'not logged in (status exit 1)')" "yes"
check "and that is in the record too" "$(contains "$(audit_details agent.login)" 'not logged in (status exit 1)')" "yes"
unset FAKE_CODEX_STATUS_RC
reset
place codex
export FAKE_CODEX_LOGIN_RC=1
pty "[]" "$AGENT" login codex --accept-ungoverned-egress
check "a login command that fails is a failed login" "$rc|$(audit_seq agent.login)" "1|started,failed"
unset FAKE_CODEX_LOGIN_RC

echo "== setup: install if missing, log in, offer the default =="
reset
export FAKE_INSTALL_DIR="$fake"
pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'y\n' "$DEFAULT_Q" $'\n')" "$AGENT" setup claude
check "it goes through" "$rc" "0"
check "the acknowledgement was asked for once, not once per step" "$(grep -c 'Do you accept that' <<<"$transcript")" "1"
check "it installed, then logged in" "$(audit_seq agent.install)|$(audit_seq agent.login)" "started,completed|started,completed"
check "both steps recorded the one acknowledgement" "$(audit_ack_ok agent.install claude prompt)|$(audit_ack_ok agent.login claude prompt)" "yes|yes"
check "an empty answer to the default question is yes" "$(cat "$default_file" 2>/dev/null || echo none)" "claude"
check "and the operator is told how to start it" "$(contains "$transcript" 'shinobi agent --accept-ungoverned-egress')" "yes"

reset
export FAKE_INSTALL_DIR="$fake"
place claude "$fake"
pty "$(steps "$ACK" $'y\n' "$DEFAULT_Q" $'n\n')" "$AGENT" setup claude
check "already installed: no install step, and declining the default is fine" \
  "$rc|$(audit_seq agent.install)|$(audit_seq agent.login)|$(cat "$default_file" 2>/dev/null || echo none)" "0|-|started,completed|none"
rm -f "$fake/claude"

reset
pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'y\n' "$DEFAULT_Q" $'y\n')" "$AGENT" setup claude
check "installed off PATH: the default cannot be set, and it says so" \
  "$rc|$(contains "$transcript" 'was not made the default')|$([[ -e $default_file ]] && echo set || echo unset)" "1|yes|unset"

reset
pty "$(steps "$ACK" $'y\n' "$CONFIRM" $'n\n')" "$AGENT" setup claude
check "a declined install ends setup before any login" "$rc|$(calls claude.runs)|$(audit_seq agent.login)" "1|0|-"

echo "== a package layout finds its own code =="
pkg="$work/pkg"
mkdir -p "$pkg/usr/bin" "$pkg/usr/lib"
cp "$ROOT/bin/shinobi-agent" "$ROOT/bin/_shinobi-common.sh" "$pkg/usr/bin/"
cp -r "$ROOT/libexec/shinobi" "$pkg/usr/lib/shinobi"
notty "$pkg/usr/bin/shinobi-agent" registry --json
check "bin/ beside lib/shinobi: the registry runs" "$rc|$(jq -r '[.agents[].id] | join(",")' <<<"$out")" "0|claude,codex"

echo
if [[ $failures -eq 0 ]]; then
  echo "agent-setup-test: PASS ($checks checks)"
else
  echo "agent-setup-test: FAIL ($failures of $checks checks)"
  exit 1
fi
