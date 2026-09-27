"""Rejection of unknown tool arguments, which FastMCP drops silently.

An unknown argument is not a no-op here. Every tool in server.py takes a closed
set of options, and the dangerous ones are the ones that select behaviour:
`nmap_scan(profile=...)` picks the scan, `http_headers(scheme=...)` picks the
URL shape. A misspelling does not raise. It leaves the parameter at its
default, the tool runs, and the caller is told the call succeeded.

The concrete case that motivated this: the MCP end-to-end test asked for
`preset="quick"` where the tool declares `profile`, and passed. `quick` is
also the default, so the test asserted a value it had already been given and
the mistake stayed invisible. A test that cannot fail is worse than no test,
because it reports the property it is not actually checking.

That mistake is a typo in a terminal. An LLM produces them constantly, and it
compounds: an agent that asks for a service scan, gets a quick scan, is told
nothing went wrong, and writes a report describing a scan it never ran. For a
distro whose stated purpose is that these are "the same tools that get people
arrested when pointed at the wrong host" (DESIGN.md), a silently defaulted
probe is a worse outcome than a refusal.

Why the fix cannot live in a tool body: by the time a decorated function runs,
the extras are already gone. mcp 1.30 loses them in three separate places:

  1. FastMCP disables the lowlevel server's JSON-Schema check outright
     (`self._mcp_server.call_tool(validate_input=False)`, fastmcp/server.py:324).
     The advertised inputSchema carries no `additionalProperties: false`, and
     nothing enforces it anyway.
  2. The pydantic model generated from the signature declares no `extra=`, so
     it defaults to "ignore" and the extra keys are not an error
     (utilities/func_metadata.py:67-85).
  3. `model_dump_one_level()` walks only the declared fields, so the extras
     are not even passed to the function (utilities/func_metadata.py:70-81).

Because of (2) and (3) the function body is structurally incapable of seeing
them: it is called as `fn(**validated_dict)`, and the unrecognised keys are
absent from that dict. This is also why a `**kwargs` parameter is not the fix
-- it would erase the signature FastMCP derives its schema from.

The only place that still holds the raw client arguments is the tool manager,
which receives the dict and dispatches on it. So the check goes there, and it
is a comparison against the same field set the dispatcher will use.

This module imports neither mcp nor pydantic on purpose: it is exercised by
tests/test-mcp-layout.sh and tests/test-static.sh, which run against a system
python3 that has neither installed. The arg model is duck-typed through
`model_fields` for the same reason.
"""
from __future__ import annotations

from typing import Any, Iterable


def accepted_arguments(arg_model: Any) -> set[str]:
    """The parameter names a tool will actually be called with.

    Duck-typed on `model_fields` (pydantic v2) or `__fields__` (v1) rather than
    imported, so this stays testable without the mcp package installed. The
    aliases FastMCP may expose are included alongside the field names, because
    a client is allowed to send either.
    """
    fields = getattr(arg_model, "model_fields", None)
    if fields is None:
        fields = getattr(arg_model, "__fields__", None)
    if fields is None:
        # No argument model at all. A tool that takes nothing can only be
        # miscalled with junk, so the caller is expected to pass an empty
        # accepted set rather than let everything through.
        return set()

    names: set[str] = set()
    for name, info in fields.items():
        names.add(name)
        alias = getattr(info, "alias", None)
        if alias:
            names.add(alias)
        # pydantic v1 carried the alias on a Config, not the field.
        validation_alias = getattr(getattr(info, "field_info", None), "alias", None)
        if validation_alias:
            names.add(validation_alias)
    return names


def unknown_arguments(arguments: Iterable[str], accepted: Iterable[str]) -> list[str]:
    """Sorted names present in `arguments` but not in `accepted`."""
    allowed = set(accepted)
    return sorted(name for name in arguments if name not in allowed)


def describe_unknown(tool: str, unknown: list[str], accepted: Iterable[str]) -> str:
    """The refusal text, naming both what was wrong and what was available.

    A refusal that only says "invalid arguments" pushes a caller that guessed
    the schema to guess again. The list of real parameter names is public
    information -- it is the tool's advertised signature -- and including it
    turns a dead end into a correction.
    """
    allowed = sorted(accepted)
    return (
        f"{tool} received unknown argument(s): {', '.join(unknown)}. "
        f"Accepted arguments: {', '.join(allowed) if allowed else '(none)'}. "
        "Arguments are matched exactly; a misspelled option is refused rather "
        "than silently replaced by its default."
    )
