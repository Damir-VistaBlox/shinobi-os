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

1. Add a function in `server.py` decorated with `@mcp.tool()`.
2. Structured parameters only — target + a closed set of options, never a
   free-form command string.
3. Call `_authorized(tool, target, argv)` to check scope and open an audit
   record. It returns `(engagement, call_id)` and must be called *before*
   anything executes, so an interrupted call still leaves evidence.
4. Build argv as a list and run it with `subprocess.run(..., shell=False)`.
5. Close the record with `_finish(engagement, call_id, tool, target, argv,
   "allowed", output)`.

`_authorized` already logs the refusal path, so a tool does not need its own
`ScopeError` handler. Anything that touches the network on the caller's
behalf must re-check scope on every redirect hop rather than only the URL it
was handed; `shinobi_recon/http.py` shows the pattern.

Anything exploitation-adjacent (Metasploit module execution, credential
spraying, etc.) should additionally require an explicit human confirmation
parameter — scope membership alone shouldn't be enough to fire those.

## What the scope gate is, and is not

`scope.yaml` is a guardrail that keeps an agent inside the window and target
list a human agreed to. It is not a sandbox: anything running as the user can
read that user's files, open sockets, and run its own commands. The agent
process in particular is not confined by this gate.

The gate is enforced at the MCP tool boundary, which is the only place the
project controls. Treat it as a strong default against an agent behaving
within its instructions, not as a boundary against a hostile one.
