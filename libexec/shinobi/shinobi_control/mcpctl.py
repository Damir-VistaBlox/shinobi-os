"""`shinobi mcp` -- offer a Shinobi MCP server to an agent that is not us.

`shinobi agent` launches somebody else's coding agent, and those agents reach
tools over MCP rather than by importing anything from this tree. Which means
the tool surface a model sees depends on the agent's own configuration, and
nothing in Shinobi's process can keep that honest at runtime. What this command
can do is make the configured state correct and say what it is:

  * `register` asks the agent's own CLI to offer the server, so the agent
    starts with Shinobi's tools instead of without them.
  * `resolve` shows how a server name resolves here, which is the same answer
    the native client acts on.

The registration is deliberately the vendor's to perform. A server wired into
an agent is a server whose scope gate is the only thing between a model and the
network, so "it is registered" has to mean the agent will actually call it, and
the vendor's CLI is the only thing that can promise that about the vendor's own
config file. See `llm/mcp.py` for the syntaxes and why `--` and the option order
are what they are.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from .llm.mcp import (
    MCPError,
    register_agent_server,
    resolve_server,
    supports_mcp_registration,
)

# Offered when the user names no agent, because these are the ones whose CLI can
# actually be told to offer a server.
KNOWN_AGENTS = ("claude", "codex")


def _resolve(args: argparse.Namespace) -> dict[str, Any]:
    argv, env = resolve_server(args.server)
    return {"server": args.server, "argv": argv, "env": env}


def _register(args: argparse.Namespace) -> dict[str, Any]:
    return register_agent_server(args.agent, args.server, force=args.force)


def _support(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "agent": args.agent,
        "supported": supports_mcp_registration(args.agent),
        "known": list(KNOWN_AGENTS),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="shinobi mcp",
        description="Offer a Shinobi MCP server to an external agent.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_resolve = sub.add_parser("resolve", help="how a server name resolves here")
    p_resolve.add_argument("server", nargs="?", default="shinobi-recon")
    p_resolve.set_defaults(handler=_resolve)

    p_register = sub.add_parser("register", help="register a server with an agent's CLI")
    p_register.add_argument("agent", help="agent executable, e.g. claude or codex")
    p_register.add_argument("--server", default="shinobi-recon")
    p_register.add_argument(
        "--force",
        action="store_true",
        help="register even if the agent already has a server by that name",
    )
    p_register.set_defaults(handler=_register)

    p_support = sub.add_parser("support", help="whether an agent can be wired")
    p_support.add_argument("agent")
    p_support.set_defaults(handler=_support)

    args = parser.parse_args(argv)
    try:
        result = args.handler(args)
    except MCPError as exc:
        print(f"shinobi mcp: {exc}", file=sys.stderr)
        return 1
    if args.command == "register":
        # A sentence an operator can act on, then the argv for the record. The
        # registration is the interesting part; the argv is how it is checked.
        print(f"{result['status']}: {result['server']} on {result['agent']}")
        print(" ".join(result["argv"]))
    else:
        print(json.dumps(result, indent=2))
    # `support` also answers in its exit status, so a caller can ask the
    # question without parsing the JSON: the launcher has to know whether the
    # agent can be wired before it tries, and "unknown" is not a failure of the
    # registration, it is the absence of one.
    if args.command == "support" and not result["supported"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
