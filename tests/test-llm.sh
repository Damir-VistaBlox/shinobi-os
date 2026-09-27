#!/usr/bin/env bash
# The LLM client: what it sends, and what it refuses to send.
#
# These tests run the real client against a real HTTP listener and a real MCP
# server over a real pipe. Nothing here mocks the code under test -- the fake
# provider and fake MCP server stand in for the *peers*, which is the only place
# a mock belongs, because the question is what this client puts on the wire and
# the peers are what answer.
#
# The cases are ordered by what could actually hurt. The per-turn approval
# property comes first because it is the one that is easy to get subtly wrong
# and impossible to notice: a loop that asks the gate once and then keeps
# talking looks identical from the outside and leaks a scan result.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"
export ROOT
export PATH="$ROOT/tests/fixtures:$PATH"
# The real-server section below launches the recon entry point out of this
# checkout, and needs a python that can import mcp -- the same interpreter
# running this suite unless a caller says otherwise.
export SHINOBI_REPO_ROOT="$ROOT"
export SHINOBI_TEST_PYTHON="${SHINOBI_TEST_PYTHON:-python3}"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

py() {
  local label="$1"
  if python3 -; then pass "$label"; else fail "$label"; fi
}

cleanup() {
  [[ -n "${PROVIDER_PID:-}" ]] && kill "$PROVIDER_PID" 2>/dev/null || true
  [[ -n "${REDIRECT_PID:-}" ]] && kill "$REDIRECT_PID" 2>/dev/null || true
}
trap cleanup EXIT

# A throwaway world: engagement, provider registry, credential state, and a
# fake provider listening on a port nothing else knows until it is written down.
sandbox() {
  cleanup
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/engagements/acme" "$SANDBOX/providers" "$SANDBOX/state"
  export SHINOBI_ENGAGEMENTS_DIR="$SANDBOX/engagements"
  export SHINOBI_ENGAGEMENT=acme
  export XDG_STATE_HOME="$SANDBOX/state"
  export SHINOBI_PROVIDERS_DIR="$SANDBOX/providers"
  export FAKE_PORT_FILE="$SANDBOX/port"
  export FAKE_HISTORY="$SANDBOX/history.jsonl"
  export FAKE_MCP_HISTORY="$SANDBOX/mcp-history.jsonl"
  unset SHINOBI_LIVE 2>/dev/null || true
  : >"$FAKE_HISTORY"
  : >"$FAKE_MCP_HISTORY"

  cat >"$SANDBOX/providers/local.toml" <<'EOF'
id = "local"
name = "Local test provider"
api = "openai-compatible"
base_url = "http://127.0.0.1:PORT/v1"
egress = "local"
requires_key = false
default_model = "test-model"
models = ["test-model", "big-model"]
reachable_on = ["127.0.0.1"]
EOF

  # The scripted turns the fake provider will play, newest queue first.
  start_provider() {
    local mode="${1:-openai}"
    local script="${2:-[]}"
    FAKE_MODE="$mode" python3 "$ROOT/tests/fixtures/fake-provider.py" <<<"$script" 2>/dev/null &
    PROVIDER_PID=$!
    for _ in $(seq 1 100); do
      [[ -s "$FAKE_PORT_FILE" ]] && break
      sleep 0.05
    done
    [[ -s "$FAKE_PORT_FILE" ]] || { echo "fake provider never bound" >&2; exit 1; }
    PORT="$(cat "$FAKE_PORT_FILE")"
    export PORT
    sed -i "s|base_url = \"http://127.0.0.1:PORT/v1\"|base_url = \"http://127.0.0.1:$PORT/v1\"|" \
      "$SANDBOX/providers/local.toml"
  }

  # An approval-gated provider, for the cloud cases.
  cloud_manifest() {
    cat >"$SANDBOX/providers/cloud.toml" <<EOF
id = "cloud"
name = "Cloud test provider"
api = "$1"
base_url = "https://93.184.216.34/v1"
egress = "cloud"
requires_key = true
default_model = "test-model"
EOF
  }

  write_scope() {
    printf '%s' "$1" >"$SANDBOX/engagements/acme/scope.yaml"
    chmod 0600 "$SANDBOX/engagements/acme/scope.yaml"
  }

  as_operator() {
    mkdir -p "$SANDBOX/state/shinobi"
    printf 'operator\n' >"$SANDBOX/state/shinobi/profile"
  }
}

echo "llm: a governed conversation, end to end"
sandbox
start_provider openai '[{"tool":"port_scan","arguments":{"target":"10.10.10.5"}},{"text":"22 and 80 are open on 10.10.10.5."}]'
write_scope 'llm:
  cloud: false
'
py "a tool call is run through MCP, and the result goes back to the provider" <<'PYEOF'
import json, os, pathlib
from shinobi_control.llm import agent, mcp

problems = []

# The conversation has to happen before any of this can be asserted on.
with mcp.Server("fake-mcp") as server:
    result = agent.run("local", "what is open on 10.10.10.5?", servers=[server])

history = [json.loads(l) for l in pathlib.Path(os.environ["FAKE_HISTORY"]).read_text().splitlines() if l]
tools = [json.loads(l) for l in pathlib.Path(os.environ["FAKE_MCP_HISTORY"]).read_text().splitlines() if l]

# Two provider requests: the question, then the question plus what the tool said.
if len(history) != 2:
    problems.append(f"expected 2 provider requests, got {len(history)}")

# The tool really ran, through MCP, with the arguments the model chose.
if len(tools) != 1 or tools[0]["name"] != "port_scan":
    problems.append(f"the tool did not run as asked: {tools}")
elif tools[0]["arguments"] != {"target": "10.10.10.5"}:
    problems.append(f"the tool got the wrong arguments: {tools[0]['arguments']}")

# The scan output -- client-confidential by construction -- really did go out.
second = json.dumps(history[1]["body"])
if "22/tcp open ssh" not in second:
    problems.append("the tool result never reached the provider")
if "10.10.10.5" not in second:
    problems.append("the target never reached the provider")

# The tool schema was advertised, so the model was not guessing.
if "port_scan" not in json.dumps(history[0]["body"]):
    problems.append("the tool was never advertised to the model")

# An OpenAI-compatible provider is sent the OpenAI shape.
messages = history[0]["body"]["messages"]
if not messages or messages[0]["role"] != "system":
    problems.append(f"the system prompt is not in the OpenAI place: {messages[:1]}")

# The answer came back.
if "22 and 80 are open" not in result.text:
    problems.append(f"the final answer was not returned: {result.text!r}")
if result.turns != 2 or result.tool_calls != 1:
    problems.append(f"the loop reported {result.turns} turns and {result.tool_calls} tool calls")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "the digest changes once a tool result is in the conversation" <<'PYEOF'
import os
from shinobi_control.llm import agent, mcp, wire

problems = []
tools = [{"name": "port_scan", "description": "", "parameters": {"type": "object"}}]

one = agent.request_digest("sys", [wire.user("what is open on the target?")], tools)
same = agent.request_digest("sys", [wire.user("what is open on the target?")], tools)
# This is the shape a second turn has: the same question, plus a scan result.
grown = agent.request_digest(
    "sys",
    [
        wire.user("what is open on the target?"),
        wire.assistant("", (wire.ToolCall("c1", "port_scan", {"target": "10.0.0.1"}),)),
        wire.tool_result(wire.ToolCall("c1", "port_scan", {"target": "10.0.0.1"}), "22/tcp open"),
    ],
    tools,
)

if one != same:
    problems.append("the same request digests differently twice, so no approval would ever match")
if one == grown:
    problems.append("adding a tool result did not change the digest, so turn one's approval covers turn two")

# The system prompt is part of it too.
if agent.request_digest("other", [wire.user("q")], tools) == one:
    problems.append("the system prompt is not covered by the digest")

# And so are the tool schemas: adding a tool is a different request.
if agent.request_digest("sys", [wire.user("q")], tools + [{"name": "x", "description": "", "parameters": {}}]) == agent.request_digest("sys", [wire.user("q")], tools):
    problems.append("the tool schemas are not covered by the digest")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

# Its own provider: a conversation needs turns left to play.
sandbox
start_provider openai '[{"tool":"port_scan","arguments":{"target":"10.10.10.5"}},{"text":"22 and 80 are open."}]'
write_scope 'llm:
  cloud: false
'
py "every turn is approved separately, on a different digest" <<'PYEOF'
import json, os, pathlib
from shinobi_control import approval, egress
from shinobi_control.llm import agent, mcp

problems = []

# An approver that records the digest it was asked about. A loop that asked once
# and then kept talking would show up here as a single ask, and the conversation
# would carry a scan result nobody approved.
asked = []

def approve(digest, provider, model, turn):
    asked.append((turn, digest))
    return "not-a-real-approval"

with mcp.Server("fake-mcp") as server:
    # A local provider does not consume approvals, so this approver's value is
    # never claimed; the loop is still obliged to ask once per turn.
    result = agent.run("local", "what is open on 10.10.10.5?", servers=[server], approve=approve)

if result.turns != 2:
    problems.append(f"expected a two-turn conversation, got {result.turns}")
if len(asked) != result.turns:
    problems.append(f"asked for approval {len(asked)} time(s) across {result.turns} turn(s)")
if len({digest for _, digest in asked}) != len(asked):
    problems.append("the same digest was approved more than once, so one approval covered two turns")

# The decisive property: the digest turn one was approved for is not the digest
# turn two needs, so the approval cannot be spent on the turn that carries the
# scan result.
if asked[0][1] == asked[1][1]:
    problems.append("turn two's request digests the same as turn one's")

# And the enforcement point agrees. An approval is bound to exact arguments, so
# the one granted for turn one's request cannot be claimed for the request that
# carries the scan result. (A *local* provider never consults an approval at
# all, so this is asserted where the check actually lives rather than through a
# provider that would skip it.)
record = approval.create(
    capability=egress.EGRESS_CAPABILITY,
    arguments={"prompt_sha256": asked[0][1], "provider": "cloud", "model": "test-model"},
    profile="operator",
    reason="test",
)
approval.set_state(record["approval_id"], "approved")
try:
    approval.consume(
        record["approval_id"],
        capability=egress.EGRESS_CAPABILITY,
        arguments={"prompt_sha256": asked[1][1], "provider": "cloud", "model": "test-model"},
        profile="operator",
    )
    problems.append("turn one's approval was spent on the request carrying the scan result")
except approval.ApprovalError as exc:
    if "different arguments" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

# And the spent approval is not claimable a second time.
try:
    approval.consume(
        record["approval_id"],
        capability=egress.EGRESS_CAPABILITY,
        arguments={"prompt_sha256": asked[1][1], "provider": "cloud", "model": "test-model"},
        profile="operator",
    )
    problems.append("the same approval was claimable twice")
except approval.ApprovalError:
    pass

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a cloud turn spends its approval, even when the connect then fails" <<'PYEOF'
import json, os, pathlib
from shinobi_control import approval, credentials, egress, policy
from shinobi_control.llm import agent, mcp, transport

problems = []
state = pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi")
state.mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")
credentials.set_key("cloud", "sk-test-not-a-real-key")

manifest = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"], "cloud.toml")
manifest.write_text(
    'id = "cloud"\nname = "Cloud"\napi = "openai-compatible"\n'
    'base_url = "https://93.184.216.34/v1"\negress = "cloud"\n'
    'requires_key = true\ndefault_model = "test-model"\n'
)
scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"], "acme", "scope.yaml")
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)

granted = []
def approve(digest, provider, model, turn):
    record = approval.create(
        capability=egress.EGRESS_CAPABILITY,
        arguments={"prompt_sha256": digest, "provider": provider, "model": model},
        profile=policy.current_profile(),
        reason=f"turn {turn}",
    )
    approval.set_state(record["approval_id"], "approved")
    granted.append(record["approval_id"])
    return record["approval_id"]

# The endpoint is a public address with nothing behind it in this environment,
# so the connect fails. That is the point: the approval was still consumed for
# this exact request, and the failure was recorded against the call.
with mcp.Server("fake-mcp") as server:
    try:
        agent.run("cloud", "what is open?", servers=[server], approve=approve, timeout=2, max_turns=1)
    except (transport.TransportError, transport.TransportRefused, agent.LoopRefused):
        pass

if not granted:
    problems.append("the cloud turn never got as far as asking for an approval")
for approval_id in granted:
    claim = pathlib.Path(approval.approval_dir(), f"{approval_id}.claimed")
    if not claim.exists():
        problems.append(f"approval {approval_id} was not spent, so it could be spent again")

# A spent approval cannot be claimed a second time.
if granted:
    try:
        approval.consume(
            granted[0],
            capability=egress.EGRESS_CAPABILITY,
            arguments={"prompt_sha256": "x", "provider": "cloud", "model": "test-model"},
            profile="operator",
        )
        problems.append("a spent approval was claimable again")
    except approval.ApprovalError:
        pass

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a cloud conversation with no approval sends nothing at all" <<'PYEOF'
import json, os, pathlib
from shinobi_control import credentials, egress, policy
from shinobi_control.llm import agent, mcp

problems = []
state = pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi")
state.mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")
credentials.set_key("cloud", "sk-test")

manifest = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"], "cloud.toml")
manifest.write_text(
    'id = "cloud"\nname = "Cloud"\napi = "openai-compatible"\n'
    'base_url = "https://93.184.216.34/v1"\negress = "cloud"\n'
    'requires_key = true\ndefault_model = "test-model"\n'
)
scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"], "acme", "scope.yaml")
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)

before = pathlib.Path(os.environ["FAKE_HISTORY"]).read_text()
with mcp.Server("fake-mcp") as server:
    try:
        agent.run("cloud", "what is open on 10.10.10.5?", servers=[server], approve=None)
        problems.append("a cloud send with no approval was permitted")
    except egress.EgressRefused as exc:
        if "requires a human approval" not in str(exc):
            problems.append(f"refused for the wrong reason: {exc}")

# The refusal has to be a refusal at the gate, before any socket is opened: a
# refusal that first tried the network would have already sent the prompt.
if pathlib.Path(os.environ["FAKE_HISTORY"]).read_text() != before:
    problems.append("a request was sent despite the refusal")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "llm: the connection is checked, not the hostname"
sandbox
start_provider redirect '[]'
write_scope 'llm:
  cloud: false
'
py "a redirect is refused, and the redirect target is never contacted" <<'PYEOF'
import json, os, pathlib, subprocess, sys, time
from shinobi_control import egress
from shinobi_control.llm import mcp, transport

# The provider that answers 302, and the one it points at.
sandbox = pathlib.Path(os.environ["XDG_STATE_HOME"]).parent

problems = []

# A second listener that records any request it receives. If the client follows
# the redirect, this file grows; that is the finding.
target_dir = sandbox
target_history = target_dir / "redirect-target.jsonl"
target_history.write_text("")
env = dict(os.environ, FAKE_HISTORY=str(target_history), FAKE_PORT_FILE=str(target_dir / "port2"),
           FAKE_MCP_HISTORY=str(target_dir / "mcp2"))
target = subprocess.Popen(
    [sys.executable, os.path.join(os.environ["ROOT"], "tests/fixtures/fake-provider.py")],
    stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, text=True,
)
target.stdin.write("[]\n")
target.stdin.flush()
target.stdin.close()
for _ in range(100):
    if (target_dir / "port2").exists():
        break
    time.sleep(0.05)
target_port = (target_dir / "port2").read_text().strip()

try:
    decision = egress.authorize("local", "a question")
    try:
        transport.post(
            decision,
            decision.provider.base_url + "/chat/completions",
            {"model": "test-model", "messages": []},
        )
        problems.append("a 302 was followed")
    except transport.TransportRefused as exc:
        if "redirect" not in str(exc):
            problems.append(f"refused for the wrong reason: {exc}")
    time.sleep(0.2)
    if target_history.read_text().strip():
        problems.append("the redirect target was contacted, so the prompt would have gone there")
finally:
    target.kill()
    target.wait(timeout=5)

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a connection to an address that was not cleared is refused before the body is sent" <<'PYEOF'
import json, os, pathlib
from shinobi_control import egress
from shinobi_control.llm import transport

problems = []
before = pathlib.Path(os.environ["FAKE_HISTORY"]).read_text()

# The gate clears a peer set. Here the set is emptied *after* clearance, which
# is what a rebind looks like from the transport's side: the destination the
# request was cleared for and the destination the socket reached are different
# facts, and only one of them was checked.
decision = egress.authorize("local", "a question")
object.__setattr__(decision, "peers", egress.Peers(
    host=decision.peers.host,
    port=decision.peers.port,
    candidates=decision.peers.candidates,
    allowed=frozenset(),
))
try:
    transport.post(
        decision,
        decision.provider.base_url + "/chat/completions",
        {"model": "test-model", "messages": [{"role": "user", "content": "SECRET"}]},
    )
    problems.append("a connection outside the cleared peer set was allowed")
except transport.TransportRefused as exc:
    if "not a peer this request was cleared for" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

# Nothing was written: the peer check happens before the request line.
after = pathlib.Path(os.environ["FAKE_HISTORY"]).read_text()
if after != before:
    problems.append("the request body was sent before the peer was checked")
if "SECRET" in after:
    problems.append("the prompt reached the provider despite the refusal")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

sandbox
start_provider openai '[]'
write_scope 'llm:
  cloud: false
'
py "the API key goes in the header and nowhere else" <<'PYEOF'
import json, os, pathlib
from shinobi_control import audit, credentials, policy
from shinobi_control.llm import agent, mcp

problems = []
policy_dir = pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi")
policy_dir.mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")

# A local provider that requires a key, so the key path is exercised.
manifest = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"], "keyed.toml")
manifest.write_text(
    f'id = "keyed"\nname = "Keyed"\napi = "openai-compatible"\n'
    f'base_url = "http://127.0.0.1:{os.environ["PORT"]}/v1"\n'
    f'egress = "local"\nrequires_key = true\ndefault_model = "test-model"\n'
    f'reachable_on = ["127.0.0.1"]\n'
)
credentials.set_key("keyed", "sk-live-DEADBEEF-secret")

before = len(pathlib.Path(os.environ["FAKE_HISTORY"]).read_text().splitlines())
with mcp.Server("fake-mcp") as server:
    agent.run("keyed", "hello", servers=[server])

lines = pathlib.Path(os.environ["FAKE_HISTORY"]).read_text().splitlines()
if len(lines) != before + 1:
    problems.append("the keyed request did not happen")
else:
    entry = json.loads(lines[-1])

    if "sk-live-DEADBEEF-secret" not in entry["headers"].get("authorization", ""):
        problems.append(f"the key was not sent as a bearer token: {entry['headers'].get('authorization')!r}")
    if "sk-live-DEADBEEF-secret" in json.dumps(entry["body"]):
        problems.append("the key leaked into the request body")
    # Exactly one header may carry it, and it has to be the one that is supposed
    # to: a key echoed into a custom header, or into a header a redirect target
    # would receive, is the same leak by another route.
    carriers = [k for k, v in entry["headers"].items() if "sk-live-DEADBEEF-secret" in v]
    if carriers != ["authorization"]:
        problems.append(f"the key travelled in unexpected headers: {carriers}")
    # And it is nowhere in the conversation, so no later turn can carry it.
    if "sk-live-DEADBEEF-secret" in json.dumps(entry["body"].get("messages", [])):
        problems.append("the key entered the conversation")
    # The provider sees the key by necessity; nothing else may. The audit trail
    # is read by anyone with the log, so a key written there outlives the
    # rotation that should have removed it.
    # Read the path from the module, so this cannot drift into asserting on a
    # file nothing writes and passing for the wrong reason.
    trail = audit.audit_path().read_text() if audit.audit_path().exists() else ""
    if "sk-live-DEADBEEF-secret" in trail:
        problems.append("the key was written to the audit trail")
    if "Bearer" in trail or "authorization" in trail.lower():
        problems.append("the audit trail records the credential header")

# And it is not in the audit trail.
audit = pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi", "audit.jsonl")
if audit.exists() and "sk-live-DEADBEEF-secret" in audit.read_text():
    problems.append("the key is in the control-plane audit trail")
log = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"], "acme", "log.jsonl")
if log.exists() and "sk-live-DEADBEEF-secret" in log.read_text():
    problems.append("the key is in the engagement log")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "an https request is pinned to the vetted address but verified against the name" <<'PYEOF'
import socket, ssl
from unittest import mock

from shinobi_control.llm import transport

problems = []

# A local provider is plain http, so the https path -- where a mistake is most
# expensive, because it decides whose certificate has to be valid -- would
# otherwise never run. There is no network here, so the socket and the TLS wrap
# are observed directly: what matters is *which* address is dialled and *which*
# name the certificate is checked against.
seen = {}

class FakeSocket:
    def getpeername(self):
        return ("93.184.216.34", 443)

    def close(self):
        pass

def fake_create_connection(address, timeout=None, source_address=None):
    seen["dialled"] = address
    return FakeSocket()

class RecordingContext:
    def wrap_socket(self, sock, server_hostname=None):
        seen["server_hostname"] = server_hostname
        return sock

with mock.patch.object(socket, "create_connection", fake_create_connection):
    connection = transport._pinned_https("93.184.216.34", RecordingContext())(
        "api.openai.com", port=443, timeout=5
    )
    connection.connect()

# The context the caller built is the one that reaches the socket, not a default
# quietly built elsewhere.
if not isinstance(connection._context, RecordingContext):
    problems.append("the connection built its own TLS context instead of using the verified one")

# Dialled the literal address the gate vetted, not the name.
if seen.get("dialled") != ("93.184.216.34", 443):
    problems.append(f"the socket dialled {seen.get('dialled')!r}, not the vetted address")
# But the certificate is verified against the name the operator wrote, which is
# what decides who we are talking to. Verifying an address literal would fail
# every legitimate cloud provider.
if seen.get("server_hostname") != "api.openai.com":
    problems.append(f"the certificate was checked against {seen.get('server_hostname')!r}")

# And the context the transport builds really does verify.
context = transport._tls_context()
if not context.check_hostname or context.verify_mode != ssl.CERT_REQUIRED:
    problems.append("the TLS context does not verify certificates and hostnames")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a response larger than the cap is refused rather than buffered" <<'PYEOF'
import os
from shinobi_control import egress
from shinobi_control.llm import transport

problems = []
decision = egress.authorize("local", "a question")
try:
    transport.post(
        decision,
        decision.provider.base_url + "/chat/completions",
        {"model": "test-model", "messages": [{"role": "user", "content": "q"}]},
        # The provider's reply is a few hundred bytes; a cap below that stands in
        # for a provider streaming something enormous.
        max_bytes=64,
    )
    problems.append("an over-sized response was buffered anyway")
except transport.TransportError as exc:
    if "exceeded" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a server the caller started is the caller's to close" <<'PYEOF'
import os
from shinobi_control.llm import agent, mcp

problems = []
server = mcp.Server("fake-mcp")

with server:
    # Entering twice would spawn a second process and drop the handle to the
    # first, leaving it alive with its pipes open after everything claims to have
    # finished. Refusing is better than quietly doubling.
    try:
        server.__enter__()
        problems.append("a server was started twice without complaint")
    except mcp.MCPError as exc:
        if "already started" not in str(exc):
            problems.append(f"refused for the wrong reason: {exc}")

    result = agent.run("local", [{"role": "user", "text": "hello"}], servers=[server])
    if result.turns != 1 or not result.text:
        problems.append(f"the conversation did not complete: {result.summary()!r}")

    # Still running, and genuinely alive: the caller entered it, so the caller
    # still owns it and the agent must not close it out from under them.
    if not server.started:
        problems.append("the agent closed a server it did not start")
    else:
        try:
            os.kill(server._process.pid, 0)
        except OSError as exc:
            problems.append(f"the server process is not alive: {exc}")

# Leaving the caller's `with` is what ends the process.
if server.started:
    problems.append("the server outlived the caller's context manager")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a tool result carrying an image is described, not forwarded" <<'PYEOF'
from shinobi_control.llm import mcp

problems = []
# A scan screenshot of a client host is client-confidential, and forwarding image
# bytes to a third-party model is a decision this project has not made. It is
# refused visibly here rather than left to whichever provider is configured.
text = mcp._content_to_text(
    {
        "content": [
            {"type": "text", "text": "port 80 open"},
            {"type": "image", "data": "iVBORw0KGgoAAAANSUhEUg==", "mimeType": "image/png"},
        ]
    },
    "screenshot",
)
if "iVBORw0KGgo" in text:
    problems.append("image bytes were passed to the model")
if "image/png" in text:
    problems.append("the image was described closely enough to be recognisable")
if "port 80 open" not in text:
    problems.append("the text alongside the image was lost")
if "not sent to the provider" not in text:
    problems.append("the omission was not made visible")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "llm: the three wire formats"
py "OpenAI and Anthropic carry the same conversation" <<'PYEOF'
from shinobi_control.llm import wire

problems = []
system = "you are helping"
messages = [
    wire.user("what is open?"),
    wire.assistant("", (wire.ToolCall("c1", "port_scan", {"target": "10.0.0.1"}),)),
    wire.tool_result(wire.ToolCall("c1", "port_scan", {"target": "10.0.0.1"}), "22/tcp open"),
]
tools = [{"name": "port_scan", "description": "scan", "parameters": {"type": "object"}}]

# OpenAI: system is a message, tool arguments travel as a JSON string, a tool
# result is a `tool` role keyed by the call id.
path, body = wire.build("openai", "m", system, messages, tools)
if path != "/chat/completions":
    problems.append(f"openai path is {path}")
roles = [m["role"] for m in body["messages"]]
if roles != ["system", "user", "assistant", "tool"]:
    problems.append(f"openai roles are {roles}")
if not isinstance(body["messages"][2]["tool_calls"][0]["function"]["arguments"], str):
    problems.append("openai tool arguments should be a string")
if body["messages"][3]["tool_call_id"] != "c1":
    problems.append("the openai tool result is not keyed to its call")
if body["tools"][0]["type"] != "function":
    problems.append("openai tools need a type discriminator")

# Anthropic: system is top-level, arguments are an object, and consecutive tool
# results are batched into one user turn.
path, body = wire.build("anthropic", "m", system, messages, tools)
if path != "/messages":
    problems.append(f"anthropic path is {path}")
if body.get("system") != system:
    problems.append("the anthropic system prompt is not top-level")
roles = [m["role"] for m in body["messages"]]
if roles != ["user", "assistant", "user"]:
    problems.append(f"anthropic roles are {roles}, expected the two tool results batched")
use = body["messages"][1]["content"][0]
if use["type"] != "tool_use" or use["input"] != {"target": "10.0.0.1"}:
    problems.append(f"the anthropic tool call is wrong: {use}")
result = body["messages"][2]["content"][0]
if result["type"] != "tool_result" or result["tool_use_id"] != "c1":
    problems.append(f"the anthropic tool result is wrong: {result}")
if "max_tokens" not in body:
    problems.append("anthropic requires max_tokens")
if body["tools"][0].get("input_schema") is None:
    problems.append("anthropic tools need input_schema")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a reply is read from either format" <<'PYEOF'
from shinobi_control.llm import wire

problems = []

# OpenAI, with arguments as a JSON string.
reply = wire.parse("openai", 200, {
    "choices": [{"message": {"role": "assistant", "content": "hi", "tool_calls": [
        {"id": "c1", "type": "function", "function": {"name": "port_scan", "arguments": '{"target":"10.0.0.1"}'}}
    ]}, "finish_reason": "tool_calls"}],
    "usage": {"prompt_tokens": 3, "completion_tokens": 4},
})
if reply.text != "hi" or len(reply.tool_calls) != 1:
    problems.append(f"openai reply misread: {reply}")
if reply.tool_calls[0].arguments != {"target": "10.0.0.1"}:
    problems.append("the openai tool arguments were not parsed")
if (reply.input_tokens, reply.output_tokens) != (3, 4):
    problems.append("openai usage misread")

# Anthropic, with arguments as an object and a thinking block to ignore.
reply = wire.parse("anthropic", 200, {
    "content": [
        {"type": "thinking", "thinking": "internal"},
        {"type": "text", "text": "hi"},
        {"type": "tool_use", "id": "c1", "name": "port_scan", "input": {"target": "10.0.0.1"}},
    ],
    "stop_reason": "tool_use",
    "usage": {"input_tokens": 5, "output_tokens": 6},
})
if reply.text != "hi" or len(reply.tool_calls) != 1:
    problems.append(f"anthropic reply misread: {reply}")
if reply.stop_reason != "tool_use" or not reply.wants_tools:
    problems.append("the anthropic stop reason was ignored")

# A tool call with no id cannot have its result matched, so it is refused rather
# than executed and then silently dropped.
for bad, why in [
    ({"choices": [{"message": {"tool_calls": [{"type": "function", "function": {"name": "x", "arguments": "{}"}}]}}]}, "an OpenAI tool call with no id"),
    ({"choices": [{"message": {"tool_calls": [{"id": "c", "type": "function", "function": {"name": "x", "arguments": "not json"}}]}}]}, "tool arguments that are not JSON"),
    ({"choices": [{"message": {"tool_calls": [{"id": "c", "type": "function", "function": {"name": "x", "arguments": "[1,2]"}}]}}]}, "tool arguments that decode to a list"),
    ({"content": [{"type": "tool_use", "id": "c", "name": "x", "input": "not an object"}]}, "an anthropic tool input that is a string"),
    ({"choices": []}, "a reply with no choices"),
    ({"content": "not a list"}, "an anthropic reply with no content array"),
]:
    try:
        wire.parse("openai" if "choices" in bad else "anthropic", 200, bad)
        problems.append(f"accepted {why}")
    except wire.WireError:
        pass

# A provider error is a WireError carrying the status, so the audit can record
# the status without recording whatever the provider said about our prompt.
try:
    wire.parse("openai", 429, {"error": {"message": "rate limited, prompt was: SECRET"}})
    problems.append("a provider error was treated as a reply")
except wire.WireError as exc:
    if exc.status != 429:
        problems.append(f"the status was lost: {exc.status}")
    if "SECRET" not in str(exc):
        problems.append("the operator should still see the provider's message")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "llm: the MCP client"
sandbox
py "a server that notifies before replying is still understood" <<'PYEOF'
import os
from shinobi_control.llm import mcp

problems = []
with mcp.Server("fake-mcp") as server:
    tools = server.tools()
    names = sorted(t.name for t in tools)
    if names != ["note", "port_scan"]:
        problems.append(f"tools/list returned {names}")
    # The fake server sends a notification before its initialize reply, which a
    # client that reads one line per request would deadlock on.
    if "port_scan" not in [t.name for t in tools]:
        problems.append("the tools did not survive the notification")
    if "$schema" in [t for t in tools if t.name == "port_scan"][0].parameters:
        problems.append("the JSON Schema dialect key should not be forwarded to a provider")
    result = server.call("port_scan", {"target": "10.0.0.1"})
    if "22/tcp open" not in result:
        problems.append(f"the tool result was not read: {result!r}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a tool the server does not have, or a duplicate name, is refused" <<'PYEOF'
import os
from shinobi_control.llm import mcp

problems = []
with mcp.Server("fake-mcp") as first:
    try:
        first.call("rm_rf", {})
        problems.append("an unknown tool was called")
    except mcp.ToolRefused:
        pass

    # Two servers offering the same tool name: the model cannot tell them
    # apart, so guessing would mean the audit names the wrong tool.
    with mcp.Server("fake-mcp") as second:
        first.tools()
        second._tools = dict(first._tools)
        try:
            mcp.gather([first, second])
            problems.append("a duplicate tool name was accepted")
        except mcp.MCPError as exc:
            if "both" not in str(exc):
                problems.append(f"refused for the wrong reason: {exc}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a server that dies, or a tool with no schema, is refused" <<'PYEOF'
import os
from shinobi_control.llm import mcp

problems = []
os.environ["FAKE_MCP_BEHAVIOUR"] = "no-schema"
try:
    with mcp.Server("fake-mcp") as server:
        server.tools()
    problems.append("a tool with no input schema was advertised")
except mcp.MCPError as exc:
    if "input schema" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

os.environ["FAKE_MCP_BEHAVIOUR"] = "crash"
try:
    with mcp.Server("fake-mcp") as server:
        server.tools()
    problems.append("a server that exits was tolerated")
except mcp.MCPError:
    pass

# And a server that is not installed at all.
try:
    mcp.Server("shinobi-no-such-server").__enter__()
    problems.append("a missing server was started")
except mcp.MCPError as exc:
    if "no MCP server named" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "a tool that refuses is reported to the model, not raised" <<'PYEOF'
import os
from shinobi_control.llm import mcp

problems = []
os.environ["FAKE_MCP_BEHAVIOUR"] = "refuse"
with mcp.Server("fake-mcp") as server:
    result = server.call("note", {"text": "hello"})
if "not in scope" not in result:
    problems.append(f"a refusal was not passed back as text: {result!r}")
if "refused" not in result:
    problems.append("the model is not told this was a refusal rather than a result")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "llm: what the operator sees"
sandbox
start_provider openai '[{"tool":"port_scan","arguments":{"target":"10.10.10.5"}},{"text":"done"}]'
write_scope 'llm:
  cloud: false
'
py "the prompt is never in argv, the logs, or the approval" <<'PYEOF'
import json, os, pathlib, subprocess, sys
from shinobi_control import approval, egress
from shinobi_control.llm import agent, mcp

problems = []
SECRET = "CONFIDENTIAL-customer-name-and-their-vpn-credentials"

# The conversation really does carry the secret, so the assertions below are
# about where it does *not* land.
with mcp.Server("fake-mcp") as server:
    result = agent.run("local", SECRET, servers=[server])

# The provider got it: that is the point of the command.
sent = pathlib.Path(os.environ["FAKE_HISTORY"]).read_text()
if SECRET not in sent:
    problems.append("the prompt never reached the provider, so this test is not testing anything")

# The engagement log holds a digest, not the text.
log = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"], "acme", "log.jsonl")
if log.exists():
    body = log.read_text()
    if SECRET in body:
        problems.append("the prompt is in the engagement log")
    if "prompt_sha256" not in body:
        problems.append("the engagement log has no digest to correlate with")

# So does the control-plane audit.
audit = pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi", "audit.jsonl")
if audit.exists():
    body = audit.read_text()
    if SECRET in body:
        problems.append("the prompt is in the control-plane audit trail")
    if "prompt_sha256" not in body:
        problems.append("the audit trail has no digest")

# And no approval was created, because a local provider needs none.
approvals = list(pathlib.Path(approval.approval_dir()).glob("*.json")) if approval.approval_dir().exists() else []
if approvals:
    problems.append(f"a local provider created {len(approvals)} approval(s)")

# The CLI refuses to take a prompt as an argument.
proc = subprocess.run(
    [sys.executable, os.path.join(os.environ["ROOT"], "libexec/shinobi/shinobi-llmctl"),
     "ask", "local", SECRET],
    capture_output=True, text=True, env=dict(os.environ, PYTHONPATH=os.environ["PYTHONPATH"]),
)
combined = proc.stdout + proc.stderr
flat = " ".join(combined.split())
if proc.returncode == 0 or "not accepted as an argument" not in flat:
    problems.append(f"the CLI did not refuse a prompt given as an argument: {combined[:200]!r}")
if SECRET in combined:
    problems.append("the CLI echoed a prompt given as an argument")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

sandbox
start_provider openai '[{"tool":"port_scan","arguments":{"target":"10.10.10.5"}},{"text":"done"}]'
write_scope 'llm:
  cloud: false
'
# The fake server above speaks the protocol this client expects, which is exactly
# why it cannot prove the client speaks it correctly. This section asks the real
# server, which is free to disagree. Skipped when the mcp package is absent, the
# same way test-mcp-e2e.sh skips: a missing optional dependency is not a bug in
# the client.
echo "llm: the real recon server"
if ! python3 -c 'import mcp' >/dev/null 2>&1; then
  echo "  SKIP (mcp package unavailable)"
else
py "the real server's tools and refusals reach the model" <<'PYEOF'
import os, pathlib
from shinobi_control.llm import mcp

problems = []
root = pathlib.Path(os.environ["SHINOBI_REPO_ROOT"])
# The suite's own sandbox, not the checkout: a test that leaves state in the
# repository is a test that can be committed. And no engagement, because the
# server is expected to refuse tool calls and that refusal has to arrive as
# text the model can read rather than as an exception that ends the turn.
sandbox_state = pathlib.Path(os.environ["XDG_STATE_HOME"])
env = dict(os.environ)
env["XDG_STATE_HOME"] = str(sandbox_state)
env["HOME"] = str(sandbox_state)
env.pop("SHINOBI_ENGAGEMENT", None)
shinobi_state = sandbox_state / "shinobi"
shinobi_state.mkdir(parents=True, exist_ok=True)
(shinobi_state / "profile").write_text("operator\n")

# Named, not pointed at a launcher script. This is the resolution an operator
# gets from `shinobi llm` in a checkout: an installed entry point if there is
# one, then a bin/ script, then the Python project under mcp-servers/.
fallback = mcp.source_tree_server("shinobi-recon")
if fallback is None:
    problems.append("the checkout has no mcp-servers/shinobi-recon to fall back to")
else:
    argv, extra = fallback
    print("  resolves to:", os.path.basename(argv[0]), argv[-1][:36])
    if "shinobi_recon.server" not in " ".join(argv):
        problems.append(f"the fallback did not name the recon project: {argv}")
    if str(root / "mcp-servers" / "shinobi-recon") not in extra.get("PYTHONPATH", ""):
        problems.append(f"the source tree was not made importable: {extra}")

# The order matters and is the whole point: an installed entry point wins,
# because on the image it is a console script from a venv that knows which
# interpreter has mcp installed. So the fallback has to be observable with the
# entry point taken out of the way, or "the fallback exists" is untestable on
# any machine that has one installed.
saved_path = os.environ.get("PATH", "")
try:
    os.environ["PATH"] = os.pathsep.join([str(root / "bin"), "/usr/bin", "/bin"])
    argv, extra = mcp._resolve_server("shinobi-recon")
    if "shinobi_recon.server" not in " ".join(argv):
        problems.append(f"without an installed entry point, the name did not reach the checkout: {argv}")
    if str(root / "mcp-servers" / "shinobi-recon") not in extra.get("PYTHONPATH", ""):
        problems.append(f"the checkout launch is not importable: {extra}")
    print("  with no entry point installed:", os.path.basename(argv[0]))
finally:
    os.environ["PATH"] = saved_path

# And when one is installed, that is what runs.
import shutil as _shutil
if _shutil.which("shinobi-recon"):
    argv, _ = mcp._resolve_server("shinobi-recon")
    if "shinobi_recon.server" in " ".join(argv):
        problems.append("an installed entry point was passed over in favour of the checkout")

# A name is not a path and not a shell fragment either: it becomes a directory
# name and a Python import, so anything that is not a package name is refused
# rather than turned into an argv.
for hostile in ("shinobi-recon;id", "$(id)", "`id`", "..", "-rf", "shinobi recon"):
    try:
        mcp._resolve_server(hostile)
        problems.append(f"a hostile server name was accepted: {hostile!r}")
    except mcp.MCPError:
        pass

# An explicit path is still how you name a server that is not in this tree, and
# it is passed as one argv element, never through a shell.
explicit = str(root / "tests" / "fixtures" / "fake-mcp")
if mcp._resolve_server(explicit)[0] != [explicit]:
    problems.append("an explicit server path was not honoured")

# Booted through the checkout's own launch rather than by name, because an
# installed entry point is meant to win and on a machine that has one this test
# would be asserting about that installation instead of about this code. The
# environment the launch needs is applied last, so it is not overwritten by the
# inherited PYTHONPATH above.
launch = dict(env)
if fallback:
    launch.update(fallback[1])
server = mcp.Server(fallback[0] if fallback else "shinobi-recon", env=launch)
with server:
    index = mcp.gather([server])
    print("  tools:", ", ".join(sorted(index)))
    for expected in ("nmap_scan", "dns_lookup"):
        if expected not in index:
            problems.append(f"the real server did not advertise {expected}")

    # A schema the client cannot read is a schema the model cannot be given.
    scan = index.get("nmap_scan")
    if scan is not None and scan.tool.parameters.get("type") != "object":
        problems.append(f"nmap_scan schema is not an object: {scan.tool.parameters.get('type')!r}")

    # An invented argument must not quietly become a default. The real server
    # refuses it; the refusal has to reach the model as text, because a dead end
    # is something the model can recover from.
    text = server.call("nmap_scan", {"target": "127.0.0.1", "not_a_real_arg": "x"})
    if "refused" not in text.lower():
        problems.append(f"an invented argument did not read as a refusal: {text[:120]!r}")

    # And a call with no engagement behind it is refused by name, so the operator
    # is told what is missing instead of being shown an empty result.
    text = server.call("dns_lookup", {"target": "nonexistent.invalid"})
    if "engagement" not in text.lower():
        problems.append(f"a missing engagement was not explained to the model: {text[:120]!r}")

    # A tool the real server does not have is refused without a round trip, so a
    # hallucinated name costs nothing.
    if server.has("definitely_not_a_tool"):
        problems.append("the client reported a tool the server does not have")
    try:
        server.call("definitely_not_a_tool", {})
        problems.append("a call to a tool that does not exist was not refused")
    except (mcp.ToolRefused, mcp.MCPError) as exc:
        print("  unknown tool refused:", str(exc)[:70])

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF
fi

py "a local provider needs no approval; a cloud one does" <<'PYEOF'
import json, os, pathlib
from shinobi_control import approval, credentials, egress, policy
from shinobi_control.llm import agent, mcp

problems = []
policy_dir = pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi")
policy_dir.mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")
credentials.set_key("cloud", "sk-test")

# Local, no approver at all: the whole point of a local provider.
with mcp.Server("fake-mcp") as server:
    result = agent.run("local", "what is open?", servers=[server], approve=None)
if result.turns != 2:
    problems.append("a local conversation should not have needed an approval")

# The same conversation against a cloud provider, with the approval withheld.
manifest = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"], "cloud.toml")
manifest.write_text(
    'id = "cloud"\nname = "Cloud"\napi = "openai-compatible"\n'
    'base_url = "https://93.184.216.34/v1"\negress = "cloud"\n'
    'requires_key = true\ndefault_model = "test-model"\n'
)
scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"], "acme", "scope.yaml")
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)
with mcp.Server("fake-mcp") as server:
    try:
        agent.run("cloud", "what is open?", servers=[server], approve=None)
        problems.append("cloud egress was permitted with no approval")
    except egress.EgressRefused as exc:
        if "requires a human approval" not in str(exc):
            problems.append(f"refused for the wrong reason: {exc}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

# A provider that asks for a tool on every turn, so the loop never converges.
sandbox
start_provider openai '[{"tool":"port_scan","arguments":{"target":"10.0.0.1"}},{"tool":"port_scan","arguments":{"target":"10.0.0.1"}},{"tool":"port_scan","arguments":{"target":"10.0.0.1"}}]'
write_scope 'llm:
  cloud: false
'
py "the loop stops rather than spending approvals forever" <<'PYEOF'
import os
from shinobi_control.llm import agent, mcp, wire

problems = []
# A model that asks for a tool every single turn never converges. Refusing to
# continue is the right outcome; the alternative is an unbounded number of
# approvals, each of which an operator granted in good faith.
def approve(digest, provider, model, turn):
    return "unused"

os.environ["FAKE_MCP_HISTORY"] = os.path.join(os.environ["XDG_STATE_HOME"], "mcp-loop.jsonl")
with mcp.Server("fake-mcp") as server:
    try:
        agent.run("local", "loop forever", servers=[server], max_turns=1, approve=approve)
        problems.append("the loop did not stop at max_turns")
    except agent.LoopRefused as exc:
        if "no final answer" not in str(exc):
            problems.append(f"refused for the wrong reason: {exc}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

py "max_turns of zero is refused rather than silently doing nothing" <<'PYEOF'
from shinobi_control.llm import agent

problems = []
try:
    agent.run("local", "hi", max_turns=0)
    problems.append("max_turns=0 was accepted")
except agent.LoopRefused:
    pass
for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

if ((fails)); then
  echo "llm tests: $fails FAILED" >&2
  exit 1
fi
echo "llm tests: PASS"
