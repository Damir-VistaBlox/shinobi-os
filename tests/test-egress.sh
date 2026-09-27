#!/usr/bin/env bash
# The egress gate: what Shinobi is allowed to send off this machine.
#
# Every case here is a refusal, because that is the whole surface. The gate has
# exactly one happy path -- a local provider, or a cloud one with written
# clearance, an operator profile, a stored key, and a human approval bound to
# this prompt's digest -- and a great many ways to be somewhere else. A gate
# that is only tested on the happy path is a gate whose denials are hypothetical.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

py() {
  local label="$1"
  if python3 -; then
    pass "$label"
  else
    fail "$label"
  fi
}

# The gate reads the engagement from the environment and the registry from
# SHINOBI_PROVIDERS_DIR, so each block builds a throwaway world rather than
# mutating the developer's.
sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/engagements/acme" "$SANDBOX/providers" "$SANDBOX/state"
  export SHINOBI_ENGAGEMENTS_DIR="$SANDBOX/engagements"
  export SHINOBI_ENGAGEMENT=acme
  export XDG_STATE_HOME="$SANDBOX/state"
  export SHINOBI_PROVIDERS_DIR="$SANDBOX/providers"
  unset SHINOBI_LIVE 2>/dev/null || true

  # A literal public address, not a hostname: the gate resolves the endpoint
  # before it spends an approval, and these tests must not need a network to do
  # that. A literal needs no resolver, so this works offline while still
  # exercising the resolution step. The shipped manifest names the real host.
  cat >"$SANDBOX/providers/openai.toml" <<'EOF'
id = "openai"
name = "OpenAI"
api = "openai"
base_url = "https://93.184.216.34/v1"
egress = "cloud"
requires_key = true
default_model = "gpt-4o"
models = ["gpt-4o", "gpt-4.1"]
EOF
  cat >"$SANDBOX/providers/ollama.toml" <<'EOF'
id = "ollama"
name = "Ollama"
api = "openai-compatible"
base_url = "http://127.0.0.1:11434/v1"
reachable_on = ["127.0.0.1", "::1"]
egress = "local"
requires_key = false
default_model = "llama3.1"
models = ["llama3.1", "qwen2.5-coder"]
EOF
  cat >"$SANDBOX/providers/liar.toml" <<'EOF'
id = "liar"
name = "Local provider pinned to the wrong peer"
api = "openai-compatible"
base_url = "http://127.0.0.1:9999/v1"
reachable_on = ["10.9.9.9"]
egress = "local"
requires_key = false
default_model = "m"
EOF
  # Kept out of the directory above: the loader must refuse this one, which
  # would stop the whole registry from loading and mask the runtime check.
  cat >"$SANDBOX/metadata-peer.toml" <<'EOF'
id = "metadata"
name = "Calls the metadata endpoint a model server"
api = "openai-compatible"
base_url = "http://127.0.0.1:9999/v1"
reachable_on = ["127.0.0.1", "169.254.169.254"]
egress = "local"
requires_key = false
default_model = "m"
EOF
  scope() {
    cat >"$SANDBOX/engagements/acme/scope.yaml"
    chmod 0600 "$SANDBOX/engagements/acme/scope.yaml"
  }
  as_operator() {
    mkdir -p "$XDG_STATE_HOME/shinobi"
    printf 'operator\n' >"$XDG_STATE_HOME/shinobi/profile"
  }
  cleanup() { rm -rf "$SANDBOX"; }
  trap cleanup EXIT
}

BASE_SCOPE='client: acme
window:
  start: "2020-01-01"
  end: "2099-01-01"
targets:
  - 10.10.10.0/24
'

echo "egress: an engagement that never considered the question"
sandbox
py "no llm block denies cloud, and local is still fine" <<'PYEOF'
import os
from shinobi_control import egress

egress.load_scope  # noqa: B018 - imported to prove the module surface exists
scope_path = os.path.join(os.environ["SHINOBI_ENGAGEMENTS_DIR"], "acme", "scope.yaml")
with open(scope_path, "w") as handle:
    handle.write("client: acme\nwindow:\n  start: '2020-01-01'\n  end: '2099-01-01'\n")
os.chmod(scope_path, 0o600)

problems = []
# The headline case: an engagement predating this feature must not send data to
# a third party just because nobody wrote anything down.
try:
    egress.authorize("openai", "summarise 10.10.10.5")
    problems.append("cloud egress allowed with no llm block")
except egress.EgressRefused as exc:
    if "has not cleared cloud egress" not in str(exc):
        problems.append(f"unhelpful refusal: {exc}")

# Local is not egress and must not be caught by the same rule.
decision = egress.authorize("ollama", "summarise 10.10.10.5")
if decision.egress != "local":
    problems.append(f"local provider reported egress {decision.egress!r}")
if decision.peer != "127.0.0.1":
    problems.append(f"local peer resolved to {decision.peer!r}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: the llm block is validated, not interpreted loosely"
sandbox
py "a misspelled, mistyped or malformed llm block denies cloud" <<'PYEOF'
import os, pathlib, stat
from shinobi_control import egress

scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"]) / "acme" / "scope.yaml"
BASE = "client: acme\nwindow:\n  start: '2020-01-01'\n  end: '2099-01-01'\n"
problems = []

def write(body, mode=0o600):
    scope.write_text(BASE + body)
    scope.chmod(mode)

def must_refuse(label, needle=None):
    try:
        egress.authorize("openai", "hi")
    except egress.EgressRefused as exc:
        if needle and needle not in str(exc):
            problems.append(f"{label}: refused for the wrong reason: {exc}")
        return
    problems.append(f"{label}: was ALLOWED")

# A typo must not read as "unset" and inherit the permissive reading.
write("llm:\n  cloudd: true\n")
must_refuse("misspelled key", "unknown field")
write("llm: true\n")
must_refuse("llm is a scalar", "must be a mapping")
write("llm:\n  cloud: 'true'\n")
must_refuse("cloud is a string", "must be true or false")
write("llm:\n  cloud: true\n  providers: openai\n")
must_refuse("providers is a scalar", "must be a list")
write("llm:\n  cloud: true\n  models: [1, 2]\n")
must_refuse("models holds non-strings", "non-empty strings")
write("llm:\n  cloud: true\n  providers: [openai, openai]\n")
must_refuse("duplicate allowlist entry", "twice")
write("llm:\n  cloud: false\n")
must_refuse("explicitly false")

# The scope file is the authorization, so it has to be a trustworthy file.
write("llm:\n  cloud: true\n", mode=0o666)
must_refuse("group/world-writable scope", "writable by group or other")
write("llm:\n  cloud: true\n", mode=0o600)
scope.unlink()
scope.symlink_to("/etc/hostname")
must_refuse("symlinked scope", "not a regular file")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: the engagement itself must be trustworthy"
sandbox
py "a missing, malformed or escaping engagement denies everything" <<'PYEOF'
import os, pathlib
from shinobi_control import egress

root = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"])
scope = root / "acme" / "scope.yaml"
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)
problems = []

def must_refuse(label, needle=None):
    try:
        egress.authorize("ollama", "hi")
        problems.append(f"{label}: was ALLOWED")
    except egress.EgressRefused as exc:
        if needle and needle not in str(exc):
            problems.append(f"{label}: refused for the wrong reason: {exc}")

# "..' has no separator, so root / '..' would walk straight out of the root.
os.environ["SHINOBI_ENGAGEMENT"] = "../escape"
must_refuse("name with ..", "malformed engagement name")
os.environ["SHINOBI_ENGAGEMENT"] = "a/b"
must_refuse("name with a separator", "malformed engagement name")
os.environ["SHINOBI_ENGAGEMENT"] = "acme"

# A symlinked engagement directory would put the scope file outside the root.
(root / "linked").symlink_to(root / "acme")
os.environ["SHINOBI_ENGAGEMENT"] = "linked"
must_refuse("symlinked engagement dir", "symlinked engagement directory")
os.environ["SHINOBI_ENGAGEMENT"] = "acme"

# With no engagement there is no clearance to check against at all.
saved = os.environ.pop("SHINOBI_ENGAGEMENT")
must_refuse("no active engagement", "no active engagement")
os.environ["SHINOBI_ENGAGEMENT"] = saved

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: a local provider must actually be local"
sandbox
py "a local manifest must pin peers, and the pin is enforced" <<'PYEOF'
import os, pathlib
from shinobi_control import egress, providerctl

scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"]) / "acme" / "scope.yaml"
scope.write_text("llm:\n  cloud: false\n")
scope.chmod(0o600)
problems = []

# The metadata address is not a model server. A manifest naming it as a peer of
# a "local" provider is refused at load time, before anything resolves.
meta_dir = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"]).parent / "meta-only"
meta_dir.mkdir(exist_ok=True)
(meta_dir / "metadata.toml").write_text(
    (pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"]).parent / "metadata-peer.toml").read_text()
)
try:
    providerctl.load_all([str(meta_dir)])
    problems.append("a reachable_on naming the metadata address loaded")
except providerctl.ProviderError as exc:
    if "link-local" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

# Now the direct case: reachable_on that excludes the address actually reached.
liar = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"]) / "liar.toml"
liar.write_text(
    'id = "liar"\nname = "Liar"\napi = "openai-compatible"\n'
    'base_url = "http://127.0.0.1:9999/v1"\nreachable_on = ["10.9.9.9"]\n'
    'egress = "local"\nrequires_key = false\ndefault_model = "m"\n'
)
try:
    egress.authorize("liar", "hi")
    problems.append("reachable_on excluding the real peer was accepted")
except egress.EgressRefused as exc:
    if "outside the peers this manifest declared" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

# And the honest declaration still works, so the check is not simply refusing
# everything local.
ok = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"]) / "honest.toml"
ok.write_text(
    'id = "honest"\nname = "Honest"\napi = "openai-compatible"\n'
    'base_url = "http://127.0.0.1:9999/v1"\nreachable_on = ["127.0.0.1"]\n'
    'egress = "local"\nrequires_key = false\ndefault_model = "m"\n'
)
decision = egress.authorize("honest", "hi")
if decision.peer != "127.0.0.1":
    problems.append(f"honest local provider reported peer {decision.peer!r}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: a cloud name that resolves onto this network is refused"
sandbox
py "a rebound cloud name is refused, and the approval is not spent" <<'PYEOF'
import os, pathlib
from shinobi_control import approval, credentials, egress, policy

scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"]) / "acme" / "scope.yaml"
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)
pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi").mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")
credentials.set_key("rebound", "sk-test")
problems = []

# A cloud manifest whose *hostname* resolves onto this network. The loader only
# checks literal addresses, so this loads cleanly -- which is the point: the
# answer can change after the manifest is written.
rebound = pathlib.Path(os.environ["SHINOBI_PROVIDERS_DIR"]) / "rebound.toml"
rebound.write_text(
    'id = "rebound"\nname = "Rebound"\napi = "openai"\n'
    'base_url = "https://localhost:8443/v1"\n'
    'egress = "cloud"\nrequires_key = true\ndefault_model = "m"\n'
)
providerctl = __import__("shinobi_control.providerctl", fromlist=["x"])
loaded = providerctl.load_all([os.environ["SHINOBI_PROVIDERS_DIR"]])
if "rebound" not in loaded:
    problems.append("the manifest should load; the rebind is a request-time fact")

# Everything else is in order: clearance, profile, key, and a valid approval.
# The refusal must come from the address, and must not consume the approval.
prompt = "what is in the instance metadata?"
record = approval.create(
    capability=egress.EGRESS_CAPABILITY,
    arguments={
        "prompt_sha256": egress.prompt_digest(prompt),
        "provider": "rebound",
        "model": "m",
    },
    profile="operator",
    reason="test",
)
approval.set_state(record["approval_id"], "approved")
try:
    egress.authorize("rebound", prompt, approval_id=record["approval_id"])
    problems.append("a cloud name resolving to loopback was authorized")
except egress.EgressRefused as exc:
    if "not a public address" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

# The whole point of checking the address first: the operator's approval is
# still unspent, so a fixed manifest does not need a second trip to the desk.
if pathlib.Path(approval.approval_dir(), f"{record['approval_id']}.claimed").exists():
    problems.append("the approval was spent on a request that was refused")
if approval.get(record["approval_id"])["state"] != "approved":
    problems.append("the approval was consumed by the refusal")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: cloud needs clearance, a profile, a key, and an approval"
sandbox
py "each missing precondition refuses cloud independently" <<'PYEOF'
import os, pathlib
from shinobi_control import approval, credentials, egress, policy

scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"]) / "acme" / "scope.yaml"
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)
pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi").mkdir(parents=True, exist_ok=True)
problems = []

def must_refuse(label, needle):
    try:
        egress.authorize("openai", "hi")
        problems.append(f"{label}: was ALLOWED")
    except egress.EgressRefused as exc:
        if needle not in str(exc):
            problems.append(f"{label}: refused for the wrong reason: {exc}")

# 1. The trust profile. An observer session must not exfiltrate by asking a
#    model a question.
pathlib.Path(policy.profile_path()).write_text("observer\n")
must_refuse("observer profile", "operator-or-above trust profile")

# 2. The key. Confirmed present or absent; never read into the decision.
pathlib.Path(policy.profile_path()).write_text("operator\n")
must_refuse("no stored key", "no API key stored")
credentials.set_key("openai", "sk-test")

# 3. The approval. With everything else in place, this is the only thing left,
#    which is the point: standing clearance alone never authorises a send.
must_refuse("no approval", "requires a human approval")

# 4. And with an approval for a *different* prompt, still refused.
prompt = "CONFIDENTIAL client summary"
digest = egress.prompt_digest(prompt)
record = approval.create(
    capability=egress.EGRESS_CAPABILITY,
    arguments={"prompt_sha256": digest, "provider": "openai", "model": "gpt-4o"},
    profile="operator",
    reason="test",
)
approval.set_state(record["approval_id"], "approved")
try:
    egress.authorize(
        "openai", prompt + " plus the API keys", approval_id=record["approval_id"]
    )
    problems.append("an approval for one prompt authorised a different one")
except egress.EgressRefused as exc:
    if "different arguments" not in str(exc):
        problems.append(f"refused for the wrong reason: {exc}")

# 5. The approval must not be a copy of the prompt.
if prompt in str(record.get("arguments")):
    problems.append("the approval record contains the prompt text")
if digest not in str(record.get("arguments")):
    problems.append("the approval record does not carry the digest")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: the approval binds prompt, provider and model"
sandbox
py "a cloud send is permitted once, and only for that exact call" <<'PYEOF'
import os, pathlib
from shinobi_control import approval, credentials, egress, policy

scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"]) / "acme" / "scope.yaml"
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)
pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi").mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")
credentials.set_key("openai", "sk-test")
problems = []

def approve(prompt, model="gpt-4o", provider="openai"):
    digest = egress.prompt_digest(prompt)
    record = approval.create(
        capability=egress.EGRESS_CAPABILITY,
        arguments={"prompt_sha256": digest, "provider": provider, "model": model},
        profile="operator",
        reason="test",
    )
    approval.set_state(record["approval_id"], "approved")
    return record["approval_id"]

prompt = "CONFIDENTIAL client summary"
aid = approve(prompt)
decision = egress.authorize("openai", prompt, approval_id=aid)
if decision.prompt_sha256 != egress.prompt_digest(prompt):
    problems.append("the decision reports a digest that is not this prompt's")
if decision.provider.id != "openai" or decision.model != "gpt-4o":
    problems.append("the decision names the wrong provider or model")

# Single use: the same approval must not carry a second send.
try:
    egress.authorize("openai", prompt, approval_id=aid)
    problems.append("an approval was spent twice")
except egress.EgressRefused as exc:
    if "already used" not in str(exc):
        problems.append(f"replay refused for the wrong reason: {exc}")

# Repointed at a larger model under an approval granted for a smaller one.
aid = approve(prompt, model="gpt-4o")
try:
    egress.authorize("openai", prompt, model="gpt-4.1", approval_id=aid)
    problems.append("an approval for gpt-4o authorised gpt-4.1")
except egress.EgressRefused as exc:
    if "different arguments" not in str(exc):
        problems.append(f"repoint refused for the wrong reason: {exc}")

# A model the manifest does not list is refused regardless of any approval.
aid = approve(prompt, model="gpt-4o")
try:
    egress.authorize("openai", prompt, model="not-a-real-model", approval_id=aid)
    problems.append("a model outside the manifest catalogue was accepted")
except egress.EgressRefused as exc:
    if "not in this manifest's catalogue" not in str(exc):
        problems.append(f"unknown model refused for the wrong reason: {exc}")

# The profile an approval was granted under is part of the binding.
digest = egress.prompt_digest(prompt)
record = approval.create(
    capability=egress.EGRESS_CAPABILITY,
    arguments={"prompt_sha256": digest, "provider": "openai", "model": "gpt-4o"},
    profile="emergency",
    reason="test",
)
approval.set_state(record["approval_id"], "approved")
try:
    egress.authorize("openai", prompt, approval_id=record["approval_id"])
    problems.append("an emergency-profile approval was honoured by an operator session")
except egress.EgressRefused:
    pass

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: allowlists restrict within the clearance"
sandbox
py "providers and models may be narrowed, and empty means none" <<'PYEOF'
import os, pathlib
from shinobi_control import approval, credentials, egress, policy

scope = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"]) / "acme" / "scope.yaml"
# The cloud cases below need a profile, a key and an approval, or they would be
# refused for those reasons and the allowlist would never be exercised at all.
pathlib.Path(os.environ["XDG_STATE_HOME"], "shinobi").mkdir(parents=True, exist_ok=True)
pathlib.Path(policy.profile_path()).write_text("operator\n")
credentials.set_key("openai", "sk-test")
problems = []


def approve(provider, model="gpt-4o"):
    digest = egress.prompt_digest("allowlist probe")
    record = approval.create(
        capability=egress.EGRESS_CAPABILITY,
        arguments={"prompt_sha256": digest, "provider": provider, "model": model},
        profile="operator",
        reason="test",
    )
    approval.set_state(record["approval_id"], "approved")
    return record["approval_id"]


def write(body):
    scope.write_text("client: acme\n" + body)
    scope.chmod(0o600)


def expect(label, provider, allowed, model=None):
    try:
        egress.authorize(provider, "allowlist probe", model=model, approval_id=approve(provider, model or "gpt-4o"))
        got = True
    except egress.EgressRefused:
        got = False
    if got != allowed:
        problems.append(f"{label}: expected {'allowed' if allowed else 'refused'}, got {got}")


# A local provider needs no cloud clearance, so the allowlist is the only gate.
write("llm:\n  providers: [ollama]\n")
expect("listed local", "ollama", True, model="llama3.1")
expect("unlisted local", "liar", False, model="llama3.1")

# An empty list is a decision, not a placeholder: it means nothing is permitted.
write("llm:\n  providers: []\n")
expect("empty list permits nothing", "ollama", False, model="llama3.1")

# Absent means unrestricted, which is the other half of that distinction.
write("llm:\n  cloud: false\n")
expect("absent list is unrestricted (local)", "ollama", True, model="llama3.1")
expect("absent list does not clear cloud", "openai", False)

# The allowlist narrows; it does not widen. Listing a cloud provider does not
# supply the cloud clearance it still needs.
write("llm:\n  providers: [openai]\n")
expect("listed cloud without cloud clearance", "openai", False)
write("llm:\n  cloud: true\n  providers: [openai]\n")
expect("listed cloud with clearance", "openai", True)

# A model allowlist applies to both egresses.
write("llm:\n  providers: [ollama]\n  models: [llama3.1]\n")
expect("listed model", "ollama", True, model="llama3.1")
expect("unlisted model", "ollama", False, model="qwen2.5-coder")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: the audit trail"
sandbox
py "refusals and intents are recorded, and never carry the prompt" <<'PYEOF'
import json, os, pathlib
from shinobi_control import egress

root = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"])
scope = root / "acme" / "scope.yaml"
scope.write_text("client: acme\nllm:\n  cloud: false\n")
scope.chmod(0o600)
log = root / "acme" / "log.jsonl"
problems = []

SECRET = "CONFIDENTIAL 10.10.10.5 sk-live-abc123"

# One refusal and one allowed local call.
try:
    egress.authorize("openai", SECRET)
except egress.EgressRefused:
    pass
egress.authorize("ollama", SECRET)

records = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
if len(records) != 2:
    problems.append(f"expected 2 records, got {len(records)}")
for record in records:
    if record.get("tool") != egress.EGRESS_CAPABILITY:
        problems.append(f"record tool is {record.get('tool')!r}")
if "sk-live-abc123" in log.read_text():
    problems.append("the prompt's secret reached the engagement log")
if "CONFIDENTIAL" in log.read_text():
    problems.append("the prompt text reached the engagement log")

# A refusal and an intent are different phases; an intent exists so a client
# that dies mid-request still leaves evidence that it tried.
phases = {r["phase"] for r in records}
if phases != {"intent", "result"}:
    problems.append(f"expected intent+result phases, got {sorted(phases)}")
verdicts = {r["verdict"] for r in records}
if verdicts != {"allowed", "refused"}:
    problems.append(f"expected allowed+refused verdicts, got {sorted(verdicts)}")

# Every record carries the digest, which is what makes the log correlatable.
digest = egress.prompt_digest(SECRET)
for record in records:
    if digest not in " ".join(record.get("args", [])):
        problems.append("a record is missing the prompt digest")

# The control-plane audit is the operator's copy, and it gets the refusal too.
audit_path = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "shinobi" / "audit.jsonl"
if not audit_path.is_file():
    problems.append("no control-plane audit written")
else:
    blob = audit_path.read_text()
    if "sk-live-abc123" in blob:
        problems.append("the prompt's secret reached the control-plane audit")
    if digest not in blob:
        problems.append("the control-plane audit does not carry the digest")
    entries = [json.loads(line) for line in blob.splitlines() if line.strip()]
    if not any(e["status"] == "refused" for e in entries):
        problems.append("the refusal is missing from the control-plane audit")
    for entry in entries:
        # This journal records arguments only as a hash, so the digest is
        # carried in `references` -- still correlatable, still not the prompt.
        if not entry.get("arguments_hash"):
            problems.append("an audited entry has no arguments_hash")
        refs = entry.get("references") or {}
        if refs.get("prompt_sha256") != digest:
            problems.append(f"references do not carry the digest: {sorted(refs)}")
        if not refs.get("call_id"):
            problems.append("references do not carry the call id")

# finish() records the outcome of a cleared call.
decision = egress.authorize("ollama", "second prompt")
egress.finish(decision, ok=True, detail="200 OK")
after = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
if not any(r["call_id"] == decision.call_id and r["phase"] == "result" for r in after):
    problems.append("finish() did not write a result for the cleared call")
if len(after) != 4:
    problems.append(f"expected 4 records after finish, got {len(after)}")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "egress: a refusal is never unlogged"
sandbox
py "a bad prompt type and a bad provider are both audited" <<'PYEOF'
import json, os, pathlib
from shinobi_control import egress

root = pathlib.Path(os.environ["SHINOBI_ENGAGEMENTS_DIR"])
scope = root / "acme" / "scope.yaml"
scope.write_text("llm:\n  cloud: true\n")
scope.chmod(0o600)
log = root / "acme" / "log.jsonl"
problems = []

# A caller bug, not an egress attempt -- but it is still an attempt to reach a
# provider, and an unlogged refusal is the one thing an audit trail cannot
# recover from.
try:
    egress.authorize("ollama", 12345)
    problems.append("a non-string prompt was accepted")
except egress.EgressRefused:
    pass

# An unknown provider is refused before the scope file is even read.
try:
    egress.authorize("no-such-provider", "hi")
    problems.append("an unknown provider was accepted")
except egress.EgressRefused:
    pass

records = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
if len(records) != 2:
    problems.append(f"expected both refusals audited, got {len(records)} records")
for record in records:
    if record["verdict"] != "refused":
        problems.append(f"a non-refusal was recorded: {record['verdict']}")
    if not record.get("detail"):
        problems.append("a refusal was recorded with no reason")

for line in problems:
    print(f"    {line}")
raise SystemExit(1 if problems else 0)
PYEOF

echo "shinobi-egress: command surface"
sandbox
scope <<<"client: acme
llm:
  cloud: false
"
if out="$(printf 'hello' | ./bin/shinobi-egress check ollama 2>&1)"; then
  grep -q '"allowed": true' <<<"$out" || fail "check did not report allowed"
  grep -q '"prompt_sha256"' <<<"$out" || fail "check does not report a digest"
  pass "check clears a local provider and reports the digest"
else
  fail "check failed for a local provider: $out"
fi
if printf 'hello' | ./bin/shinobi-egress check openai >/dev/null 2>&1; then
  fail "check allowed a cloud provider with no clearance"
else
  pass "check refuses cloud without clearance and exits non-zero"
fi
if out="$(./bin/shinobi-egress show 2>&1)"; then
  grep -q '"cloud_cleared": false' <<<"$out" || fail "show misreports clearance"
  grep -q '"registry"' <<<"$out" || fail "show omits the registry"
  pass "show reports clearance and the registry"
else
  fail "show failed: $out"
fi
if out="$(printf 'hello' | ./bin/shinobi-egress check ollama --json 2>&1)"; then
  python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$out" \
    || fail "check --json is not valid json"
  pass "check --json emits valid json"
else
  fail "check --json failed"
fi
# The prompt must not be readable from argv.
if python3 - <<'PYEOF'
import pathlib, re, sys
src = pathlib.Path("bin/shinobi-egress").read_text()
# A prompt given as an argument would sit in shell history and /proc.
sys.exit(1 if re.search(r'add_argument\("--prompt["\']', src) else 0)
PYEOF
then
  pass "there is no way to pass a prompt as an argument"
else
  fail "the CLI accepts a prompt on argv"
fi
# And a refusal must not echo the prompt either.
out="$(printf 'sk-leak-me-please' | ./bin/shinobi-egress check openai 2>&1 || true)"
grep -q 'sk-leak-me-please' <<<"$out" && fail "the refusal echoed the prompt" \
  || pass "a refusal does not echo the prompt"

if (( fails > 0 )); then
  echo "egress tests: $fails FAILED" >&2
  exit 1
fi
echo "egress tests: PASS"
