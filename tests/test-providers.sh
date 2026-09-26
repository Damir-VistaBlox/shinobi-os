#!/usr/bin/env bash
# Provider manifest registry: the loader, the egress classification, and the
# credential broker that backs it.
#
# The cases that matter here are the refusals. A registry that quietly accepts
# a malformed or misclassified provider is worse than one with no providers at
# all, because the operator cannot tell which endpoints are governed.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

# check <label> <ok|refuse> <toml body>
# Runs one manifest through the loader in a private directory and asserts it is
# accepted or refused. Each case is isolated, so one manifest cannot make
# another look valid. The body is handed over as a file rather than
# interpolated into Python source, so a case may contain any TOML it likes.
check() {
  local label="$1" expect="$2" body="$3" got dir
  dir="$(mktemp -d)"
  printf '%s\n' "$body" >"$dir/t.toml"
  got="$(python3 - "$dir" <<'PYEOF'
import sys
from shinobi_control import providerctl as pc
try:
    pc.load_all([sys.argv[1]])
except pc.ProviderError:
    print("refuse")
else:
    print("ok")
PYEOF
)"
  rm -rf "$dir"
  if [[ "$got" == "$expect" ]]; then
    pass "$label"
  else
    fail "$label (expected $expect, got $got)"
  fi
}

# py <label> <<'PYEOF' ... PYEOF
# Runs an assertion block; a non-zero exit is one failure, not an abort, so the
# remaining cases still run and the summary stays honest.
py() {
  local label="$1"
  if python3 -; then
    pass "$label"
  else
    fail "$label"
  fi
}

# A cloud manifest, parameterised by URL. Used for the endpoint-integrity cases.
cloud() {
  cat <<EOF
id = "t"
name = "T"
api = "openai"
base_url = "$1"
egress = "cloud"
requires_key = true
default_model = "m"
EOF
}

echo "provider manifests: shipped defaults"
py "3 shipped manifests classify their egress" <<'PYEOF'
import pathlib, sys
from shinobi_control import providerctl as pc

problems = []
providers = pc.load_all([pathlib.Path("providers")])
for required in ("openai", "anthropic", "ollama"):
    if required not in providers:
        problems.append(f"missing shipped manifest: {required}")
for pid, provider in sorted(providers.items()):
    if provider.egress not in {"cloud", "local"}:
        problems.append(f"{pid}: egress is {provider.egress!r}")
    if provider.egress == "cloud":
        if not provider.base_url.startswith("https://"):
            problems.append(f"{pid}: cloud provider is not https")
        if provider.reachable_on:
            problems.append(f"{pid}: cloud provider declares reachable_on")
    if provider.egress == "local" and not provider.reachable_on:
        problems.append(f"{pid}: local provider has no reachable_on")
    if not provider.default_model:
        problems.append(f"{pid}: no default model")
    if provider.requires_key and not provider.reachable_on and provider.egress == "local":
        problems.append(f"{pid}: the local reference provider should not need a key")

for line in problems:
    print(f"    {line}", file=sys.stderr)
sys.exit(1 if problems else 0)
PYEOF

echo "provider manifests: cloud endpoints are refused when unsafe"
check "cloud over http" refuse "$(cloud 'http://api.example.com/v1')"
check "cloud at loopback" refuse "$(cloud 'https://127.0.0.1/v1')"
check "cloud at ipv6 loopback" refuse "$(cloud 'https://[::1]/v1')"
check "cloud at metadata endpoint" refuse "$(cloud 'https://169.254.169.254/latest')"
check "cloud at rfc1918" refuse "$(cloud 'https://10.0.0.5/v1')"
check "cloud at cgnat" refuse "$(cloud 'https://100.64.0.1/v1')"
check "cloud with credentials in url" refuse "$(cloud 'https://user:pw@api.example.com/v1')"
check "cloud with a query string" refuse "$(cloud 'https://api.example.com/v1?k=v')"
check "cloud with a fragment" refuse "$(cloud 'https://api.example.com/v1#f')"
check "cloud with a port only" refuse "$(cloud 'https:///v1')"
check "cloud with no scheme" refuse "$(cloud 'api.example.com/v1')"
check "cloud over ftp" refuse "$(cloud 'ftp://api.example.com/v1')"
check "well-formed cloud" ok "$(cloud 'https://api.example.com/v1')"

echo "provider manifests: egress must be declared, and local must be pinned"
check "unknown egress" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "sometimes"
requires_key = true
default_model = "m"
'
check "egress omitted entirely" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
requires_key = true
default_model = "m"
'
check "egress misspelled" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egres = "cloud"
requires_key = true
default_model = "m"
'
check "local without reachable_on" refuse '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "http://127.0.0.1:1234/v1"
egress = "local"
requires_key = false
default_model = "m"
'
check "local with reachable_on" ok '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "http://127.0.0.1:1234/v1"
reachable_on = ["127.0.0.1", "::1", "localhost"]
egress = "local"
requires_key = false
default_model = "m"
'
check "local naming a public peer" refuse '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "https://api.example.com/v1"
reachable_on = ["93.184.216.34"]
egress = "local"
requires_key = false
default_model = "m"
'
check "cloud declaring reachable_on" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
reachable_on = ["127.0.0.1"]
egress = "cloud"
requires_key = true
default_model = "m"
'
check "local over http at a public address" refuse '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "http://93.184.216.34/v1"
reachable_on = ["127.0.0.1"]
egress = "local"
requires_key = false
default_model = "m"
'
check "reachable_on that is empty" refuse '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "http://127.0.0.1:1234/v1"
reachable_on = []
egress = "local"
requires_key = false
default_model = "m"
'
check "reachable_on naming a bare underscore host" refuse '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "http://127.0.0.1:1234/v1"
reachable_on = ["bad_host"]
egress = "local"
requires_key = false
default_model = "m"
'

echo "provider manifests: schema hygiene"
check "unknown field" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
default_model = "m"
egres = "cloud"
'
check "unknown api" refuse '
id = "t"
name = "T"
api = "grpc"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
default_model = "m"
'
check "no model and no default" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
'
check "default_model outside models" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
models = ["a"]
default_model = "b"
'
check "duplicate model in models" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
models = ["a", "a"]
default_model = "a"
'
check "models as a scalar, not an array" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
models = "a,b"
default_model = "a"
'
check "requires_key not a boolean" refuse '
id = "t"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = "yes"
default_model = "m"
'
check "id that cannot be a credential key" refuse '
id = "../escape"
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
default_model = "m"
'
check "empty id" refuse '
id = ""
name = "T"
api = "openai"
base_url = "https://api.example.com"
egress = "cloud"
requires_key = true
default_model = "m"
'
check "well-formed minimal manifest" ok '
id = "t"
name = "T"
api = "openai-compatible"
base_url = "https://gw.example.com/v1"
egress = "cloud"
requires_key = true
default_model = "m"
'

echo "provider manifests: layering and duplicates"
py "layers coexist; duplicates and malformed manifests fail loudly" <<'PYEOF'
import os, pathlib, sys, tempfile
from shinobi_control import providerctl as pc

problems = []
GOOD = (
    'id = "x"\nname = "X"\napi = "openai"\n'
    'base_url = "https://a.example.com"\negress = "cloud"\n'
    'requires_key = true\ndefault_model = "m"\n'
)

def expect_refusal(label, fn):
    try:
        fn()
    except pc.ProviderError:
        return
    problems.append(label)

with tempfile.TemporaryDirectory() as d:
    base, over = pathlib.Path(d) / "base", pathlib.Path(d) / "over"
    base.mkdir()
    over.mkdir()
    (base / "x.toml").write_text(GOOD)
    (over / "y.toml").write_text(
        GOOD.replace('"x"', '"y"').replace("a.example.com", "b.example.com")
    )

    # Distinct ids across layers coexist; the operator layer adds to the set.
    try:
        both = pc.load_all([base, over])
        if set(both) != {"x", "y"}:
            problems.append(f"layered load should hold both, got {sorted(both)}")
    except pc.ProviderError as exc:
        problems.append(f"layered load refused: {exc}")

    # A duplicate id across layers is an error, not a silent override: an
    # operator addition that shadows a packaged provider must be visible.
    (over / "x.toml").write_text(GOOD)
    expect_refusal("duplicate id across layers was accepted silently",
                   lambda: pc.load_all([base, over]))

    # One malformed manifest fails the whole registry, so a caller can trust
    # that everything it got is governed.
    (over / "x.toml").unlink()
    (over / "broken.toml").write_text('id = "z"\nname =')
    expect_refusal("a malformed manifest did not fail the registry",
                   lambda: pc.load_all([base, over]))
    (over / "broken.toml").unlink()

    # An override replaces the search entirely, which is what tests and a pinned
    # deployment rely on: the packaged defaults are not merged in behind it.
    os.environ["SHINOBI_PROVIDERS_DIR"] = str(over)
    try:
        if set(pc.load_all()) != {"y"}:
            problems.append(
                f"SHINOBI_PROVIDERS_DIR should replace the search, got {sorted(pc.load_all())}"
            )
        if pc.provider_dirs() != [over]:
            problems.append(f"override leaked other dirs: {pc.provider_dirs()}")
    finally:
        del os.environ["SHINOBI_PROVIDERS_DIR"]

    # An override pointing nowhere is an error, not an empty registry.
    os.environ["SHINOBI_PROVIDERS_DIR"] = str(pathlib.Path(d) / "absent")
    try:
        expect_refusal("an absent override directory loaded as empty",
                       lambda: pc.load_all())
    finally:
        del os.environ["SHINOBI_PROVIDERS_DIR"]

for line in problems:
    print(f"    {line}", file=sys.stderr)
sys.exit(1 if problems else 0)
PYEOF

echo "provider credentials: the broker"
py "keys round-trip at 0600, and bad input is refused" <<'PYEOF'
import os, pathlib, sys, tempfile
from shinobi_control import credentials as cr

problems = []

def expect_refusal(label, fn):
    try:
        fn()
    except cr.CredentialError:
        return
    problems.append(label)

# Force the file backend regardless of how this host is configured, so the test
# means the same thing on a workstation and on the live image.
os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()
os.environ.pop("SHINOBI_LIVE", None)

expect_refusal("empty key", lambda: cr.set_key("p", ""))
expect_refusal("whitespace-only key", lambda: cr.set_key("p", "   "))
expect_refusal("key with a newline", lambda: cr.set_key("p", "sk-a\nsk-b"))
expect_refusal("key with a NUL", lambda: cr.set_key("p", "sk-a\x00b"))
expect_refusal("non-string key", lambda: cr.set_key("p", None))

# The id grammar is one grammar: what the manifest loader accepts is what the
# credential store can address, and a path must never come out of an id.
for bad in ("../escape", "a/b", "", "UPPER", "has space", ".hidden", "x" * 80):
    expect_refusal(f"credential id {bad!r}", lambda b=bad: cr.set_key(b, "sk-x"))
    expect_refusal(f"get_key with id {bad!r}", lambda b=bad: cr.get_key(b))

cr.set_key("roundtrip", "sk-secret-value")
if cr.get_key("roundtrip") != "sk-secret-value":
    problems.append("a stored key did not come back intact")
if not cr.has_key("roundtrip"):
    problems.append("has_key is false for a key that was just stored")
if cr.has_key("never-stored"):
    problems.append("has_key is true for a key that was never stored")

key_file = cr._key_path("roundtrip")
if key_file.stat().st_mode & 0o777 != 0o600:
    problems.append(f"stored key is mode {key_file.stat().st_mode & 0o777:o}, expected 600")
if key_file.is_symlink() or not key_file.is_file():
    problems.append("the stored key is not a plain file")
if cr.key_dir().stat().st_mode & 0o077:
    problems.append("the credential directory is readable beyond its owner")

if not cr.forget_key("roundtrip"):
    problems.append("forget_key reported nothing to remove")
if cr.has_key("roundtrip"):
    problems.append("a key survived forget_key")
if cr.forget_key("roundtrip"):
    problems.append("forget_key claimed to remove a key that was already gone")

# A directory cannot be read as a key, and a group-readable key file is refused
# rather than quietly accepted: the mode is the only thing protecting it.
os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()
cr.set_key("perms", "sk-value")
os.chmod(cr._key_path("perms"), 0o644)
expect_refusal("a world-readable key file was accepted",
               lambda: cr.get_key("perms"))
os.chmod(cr._key_path("perms"), 0o600)
if cr.get_key("perms") != "sk-value":
    problems.append("a correctly-permissioned key became unreadable")

# A symlink planted where the key should be. The store stats the link rather
# than following it, so a readable path elsewhere cannot be redirected into the
# credential slot -- and a key that is absent must read as absent, not as
# whatever the link happens to point at. A symlink's own mode is 0o777, so the
# group/world-access refusal is what actually stops this; the regular-file
# check is the second layer behind it, and removing both is what this test
# catches.
os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()
cr.key_dir().mkdir(parents=True, exist_ok=True)
os.chmod(cr.key_dir(), 0o700)
elsewhere = pathlib.Path(tempfile.mkdtemp()) / "elsewhere"
elsewhere.write_text("sk-attacker-controlled")
os.symlink(elsewhere, cr.key_dir() / "planted.key")
expect_refusal("a symlinked credential file was read through",
               lambda: cr.get_key("planted"))
if cr.has_key("planted"):
    problems.append("has_key followed a symlink and reported a key that is not there")

for line in problems:
    print(f"    {line}", file=sys.stderr)
sys.exit(1 if problems else 0)
PYEOF

echo "shinobi-provider: command surface"
if out="$(./bin/shinobi-provider check 2>&1)"; then
  grep -q "manifest(s) valid" <<<"$out" || fail "check does not report validity"
  pass "check validates the shipped registry"
else
  fail "check failed: $out"
fi
if out="$(./bin/shinobi-provider list 2>&1)"; then
  grep -q "ollama" <<<"$out" || fail "list omits the shipped local provider"
  grep -q "EGRESS" <<<"$out" || fail "list has no egress column"
  pass "list shows providers and their egress"
else
  fail "list failed: $out"
fi
if out="$(./bin/shinobi-provider list --json 2>&1)" \
  && python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["providers"]' <<<"$out"; then
  pass "list --json emits valid json"
else
  fail "list --json is not valid json"
fi
./bin/shinobi-provider inspect ollama >/dev/null 2>&1 \
  || fail "inspect of a real provider failed"
pass "inspect reads a real manifest"
if ./bin/shinobi-provider inspect no-such-provider >/dev/null 2>&1; then
  fail "inspect of an unknown provider succeeded"
else
  pass "inspect refuses an unknown id"
fi
if ./bin/shinobi-provider no-such-action >/dev/null 2>&1; then
  fail "an unknown action was accepted"
else
  pass "an unknown action exits non-zero"
fi
# The secret must never be readable from argv: argv is visible to every process
# on the box and lands in shell history. The key action reads a prompt or stdin.
if python3 - <<'PYEOF'
import pathlib, re, sys
src = pathlib.Path("libexec/shinobi/shinobi_control/providerctl.py").read_text()
block = src.split('if action == "key":', 1)[1].split('if action == "forget":', 1)[0]
sys.exit(1 if re.search(r"secret\s*=\s*sys\.argv", block) else 0)
PYEOF
then
  pass "the key action never reads a secret from argv"
else
  fail "the key action can read a secret from argv"
fi

# The non-interactive path a secret manager would use: the key arrives on stdin.
# It must round-trip into the store, must not appear in the command's output, and
# must leave nothing behind when forgotten.
state="$(mktemp -d)"
out="$(printf 'sk-piped-secret' | XDG_STATE_HOME="$state" ./bin/shinobi-provider key openai 2>&1)"
if grep -q 'sk-piped-secret' <<<"$out"; then
  fail "the key action echoed the secret it was given"
else
  pass "key reads from stdin without echoing the secret"
fi
if ! XDG_STATE_HOME="$state" PYTHONPATH="$ROOT/libexec/shinobi" python3 -c '
import sys
from shinobi_control import credentials
sys.exit(0 if credentials.get_key("openai") == "sk-piped-secret" else 1)'; then
  fail "the key piped on stdin was not stored"
else
  pass "a piped key is stored and reads back"
fi
if ! XDG_STATE_HOME="$state" ./bin/shinobi-provider list 2>&1 | grep -q '^ openai'; then
  fail "list did not report the newly stored key"
else
  pass "list reports the stored key"
fi
# A provider that takes no key must refuse to be given one, rather than storing
# a credential nothing will ever read.
if printf 'sk-unwanted' | XDG_STATE_HOME="$state" ./bin/shinobi-provider key ollama >/dev/null 2>&1; then
  fail "a no-key provider accepted a key"
else
  pass "a no-key provider refuses to be given a key"
fi
XDG_STATE_HOME="$state" ./bin/shinobi-provider forget openai >/dev/null 2>&1
if XDG_STATE_HOME="$state" PYTHONPATH="$ROOT/libexec/shinobi" python3 -c '
import sys
from shinobi_control import credentials
sys.exit(0 if credentials.has_key("openai") else 1)'; then
  fail "forget left the key in place"
else
  pass "forget removes the stored key"
fi
rm -rf "$state"

if (( fails > 0 )); then
  echo "provider tests: $fails FAILED" >&2
  exit 1
fi
echo "provider tests: PASS"
