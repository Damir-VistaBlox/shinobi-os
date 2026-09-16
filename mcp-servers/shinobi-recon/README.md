# shinobi-recon

MCP server exposing Kali recon tools to an AI agent, gated by an engagement's
`scope.yaml` and audit-logged to `log.jsonl`. See `../../DESIGN.md` for the
overall architecture.

## Run standalone (for testing)

```
export SHINOBI_ENGAGEMENT=test
export SHINOBI_ENGAGEMENT_DIR=/path/to/engagements/test
pipx run --spec . shinobi-recon
```

Normally this is launched for you by `shinobi agent`, which sets those two
env vars from the active engagement before starting the agent.

## Adding a new tool

1. Add a function in `server.py` decorated with `@mcp.tool()`.
2. Structured parameters only — target + a closed set of options, never a
   free-form command string.
3. Call `require_in_scope(target)` before building the argv, inside a
   try/except that calls `log_call(None, ..., "refused", ...)` on
   `ScopeError`.
4. Build argv as a list and run it with `subprocess.run(..., shell=False)`.
5. Call `log_call(engagement, ..., "allowed", output)` after it runs.

Anything exploitation-adjacent (Metasploit module execution, credential
spraying, etc.) should additionally require an explicit human confirmation
parameter — scope membership alone shouldn't be enough to fire those.
