# shinobi-recon

MCP server exposing Kali recon tools to an AI agent, gated by an engagement's
`scope.yaml` and audit-logged to `log.jsonl`. See `../../DESIGN.md` for the
overall architecture.

## Run standalone (for testing)

```
export SHINOBI_ENGAGEMENT=test
export SHINOBI_ENGAGEMENTS_DIR=/path/to/engagements   # the root, not the engagement
pipx run --spec . shinobi-recon
```

`SHINOBI_ENGAGEMENTS_DIR` is the directory that *contains* engagements, and
defaults to `$XDG_DATA_HOME/shinobi/engagements`. The engagement is located
inside it by name.

`SHINOBI_ENGAGEMENT_DIR` is ignored on purpose. It used to name the
engagement directory directly, which meant anything able to launch this
process could point the scope gate at a `scope.yaml` it had written itself --
and the gate would authorize exactly what that file said. See
`shinobi_recon/scope.py:current_engagement`.

Normally this is launched for you by `shinobi agent`, which sets these env
vars from the active engagement before starting the agent.

## Adding a new tool

1. Add a manifest in `../../tools/`. It is the single source of truth for the
   tool's policy — binary, timeout, risk, and whether it needs scope or
   approval. Every field is required except `binary`, and an unknown field is an
   error, so a typo like `requries_scope` is caught rather than silently read as
   "not set".
2. Add a function in `server.py` decorated with `@mcp.tool()`, and resolve its
   policy at module scope with `_TOOL = registry.require("your_mcp_tool")`.
   Because that runs at import, a tool with no valid manifest stops the server
   from starting instead of being served ungoverned.
3. Take the binary and timeout from the manifest (`_TOOL.binary`,
   `_TOOL.timeout_seconds`) rather than restating them. They used to be
   duplicated as constants in `server.py` and drifted from the manifests.
4. Structured parameters only — target + a closed set of options, never a
   free-form command string.
5. Call `_authorized(tool, target, argv)` to check scope and open an audit
   record. It returns `(engagement, call_id)` and must be called *before*
   anything executes, so an interrupted call still leaves evidence.
6. Build argv as a list and run it with `subprocess.run(..., shell=False)`.
   Use `_binary(_TOOL)` if the tool spawns a subprocess; it raises if the
   manifest names no binary.
7. Close the record with `_finish(engagement, call_id, tool, target, argv,
   "allowed", output)`.

`_authorized` already logs the refusal path, so a tool does not need its own
`ScopeError` handler. Anything that touches the network on the caller's
behalf must re-check scope on every redirect hop rather than only the URL it
was handed; `shinobi_recon/httpclient.py` shows the pattern.

Step 4's "closed set of options" is enforced, not just conventional. mcp
discards arguments a tool does not declare, and a discarded option that
selects behaviour is not a no-op: the tool runs on its default and reports
success. A guard in `argcheck.py`, installed on the tool manager at import,
refuses the call instead, names the offending key, and lists what is actually
accepted. A tool needs nothing for this — it follows from having a signature —
but it does mean a new tool gets strict arguments for free, and `**kwargs` must
not be used, since that would erase the signature the guard checks against.

The refusal is audited like any other, recording the rejected key *names* and
not their values: the values are unvalidated model text, and the names are
what an operator needs in order to work out what the agent was trying to ask
for.

`tests/test-tool-registry.sh` enforces the anti-drift properties: every MCP
tool in `server.py` must have a manifest, the values `server.py` uses must come
from the manifest, and the old hardcoded timeout constants must stay gone.

## Approvals

A manifest with `requires_approval = true` makes its tool run only against an
explicit human approval. `nmap_scan` is the only such tool today: it is the one
recon tool here that reaches hosts with packets rather than reading a public
record, and an active scan is visible to the target.

The flow, which `tests/test-approvals.sh` covers end to end:

1. The agent calls the tool without `approval_id`. The call is **refused**,
   the refusal is audited, and an approval request is created.
2. A human runs `shinobi approval list`, then `shinobi approval approve <id>`.
3. The agent retries with `approval_id=<id>`. The approval is claimed and the
   call proceeds.

An approval authorizes exactly one call:

- it is bound to the capability, the trust profile, and the canonical
  arguments, so an approval for `nmap 10.0.0.5 quick` cannot be spent on
  `10.0.0.6`, on `service`, or with an extra argument;
- it is single-use, claimed atomically, so two concurrent callers cannot both
  spend it;
- it expires, five minutes after it was requested by default (`--ttl` on
  `shinobi approval request` sets this);
- scope is still checked first, so an out-of-scope target is refused without an
  approval ever being created.

The claim logic lives in `shinobi_control/approval.py` and is reached through
the `shinobi-approval` CLI rather than reimplemented in the MCP server; two
copies of a security rule eventually disagree and the laxer one wins.

## What the scope gate is, and is not

`scope.yaml` is a guardrail that keeps an agent inside the window and target
list a human agreed to. It is not a sandbox: anything running as the user can
read that user's files, open sockets, and run its own commands. The agent
process in particular is not confined by this gate.

The gate is enforced at the MCP tool boundary, which is the only place the
project controls. Treat it as a strong default against an agent behaving
within its instructions, not as a boundary against a hostile one.
