"""A minimal MCP client, enough to let a model call Shinobi's own tools.

This speaks JSON-RPC 2.0 over a server's stdio, which is the same transport
`claude`, `codex` and friends already use to reach those servers. Driving the
tools through MCP rather than importing them is the point, and it is not a
stylistic preference:

  * The scope gate stays the single authority on what a tool may touch. Calling
    a tool over MCP goes through exactly the same `server.py` path an external
    agent uses -- same target validation, same approval, same audit records.
    An in-process shortcut would need its own copy of that logic, and the laxer
    of two copies of a security rule is the one that ends up being used.

  * The client cannot see engagement state, credentials, or the engagement
    directory, so there is nothing here for a confused model to talk it out of.

What it does *not* do: trust the model. A tool name the model invents is refused,
the server's own schema decides what arguments are allowed, and the reply is
returned to the loop as text for the model to reason about -- never as
instructions to this process.
"""
from __future__ import annotations

import json
import os
import re
import select
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# A server name becomes a directory name and a Python import, so it is held to
# what a package name can be rather than to whatever a caller passed.
_NAME_RE = re.compile(r"[a-z][a-z0-9_]*(?:-[a-z0-9_]+)*")

CLIENT_NAME = "shinobi-llm"
CLIENT_VERSION = "1"

# The protocol revision this client speaks. Servers negotiate down, so this is
# the version requested rather than assumed.
PROTOCOL_VERSION = "2025-06-18"

# A model that has produced an empty or enormous tool name is not going to
# produce a good one on the next attempt, and a hung server should not hold the
# loop open forever.
CALL_TIMEOUT_S = 300
MAX_LINE_BYTES = 8 * 1024 * 1024
_READ_CHUNK = 64 * 1024


class MCPError(RuntimeError):
    """An MCP server refused a request, or spoke something unreadable."""


class ToolRefused(MCPError):
    """The model asked for something no server will run.

    Kept distinct from a server-side tool failure: this one is a dead end (the
    model invented a tool, or one was withdrawn) and the loop should tell the
    model so rather than abort.
    """


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    parameters: dict[str, Any]

    def as_openai(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters": self.parameters,
        }


def _resolve_server(command: str | list[str]) -> tuple[list[str], dict[str, str]]:
    """Resolve a server name to an argv, plus any environment it needs.

    An argv is taken as given, and a name is resolved in order of preference:
    an explicit path, an installed entry point, a script beside this client in
    `bin/`, then the Python project under `mcp-servers/`.

    The installed entry point is preferred over the source tree on purpose. On
    the image `shinobi-recon` is a console script from the venv that has `mcp`
    installed, and launching the source tree instead would use whichever
    `python3` came first and fail on a missing dependency. The other two are for
    a checkout, where nothing is installed at all.
    """
    if isinstance(command, list):
        if not command or not all(isinstance(part, str) for part in command):
            raise MCPError(f"an MCP server argv has to be a non-empty list of strings, not {command!r}")
        return list(command), {}
    if os.sep in command:
        return [command], {}
    found = shutil.which(command)
    if found:
        return [found], {}
    sibling = Path(__file__).resolve().parents[4] / "bin" / command
    if sibling.is_file():
        return [str(sibling)], {}
    source = source_tree_server(command)
    if source is not None:
        return source
    raise MCPError(
        f"no MCP server named {command!r} on PATH, and no {command} in the source tree; "
        "refusing to run a conversation with no tools.\n"
        "  The recon server ships with the image (pip-installed into /opt/shinobi/venv),\n"
        "  not with the .deb, which declares no Python MCP dependency.\n"
        "  In a checkout this resolves to mcp-servers/<name>/ automatically.\n"
        "  Or ask without tools: --server ''"
    )


def source_tree_server(command: str) -> tuple[list[str], dict[str, str]] | None:
    """How to launch a Python MCP server out of this checkout, if one is named.

    The layout is the repository's, not this client's: `mcp-servers/<name>/` is a
    Python project whose `<name>.server:main` is its console entry point. Naming
    the server is naming the directory, so nothing here is specific to recon.

    Public because "run this server from my checkout" is a reasonable thing for a
    caller to want without going through the installed-entry-point preference that
    `Server` applies first.
    """
    if not _NAME_RE.fullmatch(command):
        # A name with a path separator or shell metacharacter in it is not a
        # directory name, and building an argv or an import out of one would be
        # the injection.
        return None
    project = Path(__file__).resolve().parents[4] / "mcp-servers" / command
    # The project is named with a hyphen and the package inside it with an
    # underscore, which is what every Python project does and what this one
    # does: mcp-servers/shinobi-recon/shinobi_recon/server.py.
    package = command.replace("-", "_")
    if not (project / package / "server.py").is_file():
        return None
    root = str(project)
    existing = os.environ.get("PYTHONPATH", "")
    return (
        [sys.executable, "-c", f"import {package}.server as _s; _s.main()"],
        {"PYTHONPATH": f"{root}{os.pathsep}{existing}" if existing else root},
    )


class Server:
    """One MCP server subprocess, addressed by JSON-RPC id."""

    def __init__(self, command: str | list[str], *, env: dict[str, str] | None = None) -> None:
        # A name is resolved to a command; an argv is taken as given. The second
        # form exists so a caller that already knows how a server is launched --
        # the source-tree fallback, or a wrapper with its own interpreter -- does
        # not have to write a shell script to a temporary file to say so.
        self._argv_input = command
        self.command = command if isinstance(command, str) else " ".join(command)
        self._process: subprocess.Popen | None = None
        self._next_id = 0
        self._env = env
        self._tools: dict[str, Tool] | None = None
        # Line assembly for the reply stream, owned here so that a `select` on
        # the pipe and the bytes already read from it cannot disagree.
        self._buffer = b""

    # -- lifecycle ---------------------------------------------------------

    @property
    def started(self) -> bool:
        """Whether a subprocess is currently running for this server.

        Ownership of that subprocess has to be unambiguous. A server that is
        entered twice spawns a second process and drops the handle to the first,
        which then outlives every exit and keeps its stdio pipes open.
        """
        return self._process is not None

    def __enter__(self) -> "Server":
        if self.started:
            raise MCPError(f"{self.command}: already started, so entering it again is a bug")
        argv, extra_env = _resolve_server(self._argv_input)
        # A source-tree launch is only importable if its path survives, and a
        # caller that passes a copy of its own environment would otherwise wipe
        # it out by supplying the inherited PYTHONPATH. So the path the resolver
        # needs is prepended to whatever the caller ends up with, rather than
        # being updated in and then overwritten.
        needed = extra_env.pop("PYTHONPATH", None)
        environ = dict(os.environ)
        environ.update(extra_env)
        if self._env is not None:
            environ.update(self._env)
        if needed is not None:
            existing = environ.get("PYTHONPATH", "")
            environ["PYTHONPATH"] = f"{needed}{os.pathsep}{existing}" if existing else needed
        try:
            self._process = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=None,  # inherited: a server's own diagnostics belong on the terminal
                env=environ,
                bufsize=0,
            )
        except OSError as exc:
            raise MCPError(f"could not start MCP server {self.command!r}: {exc}") from exc
        self._handshake()
        return self

    def __exit__(self, *_exc: object) -> None:
        process = self._process
        self._process = None
        if process is None:
            return
        try:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            process.wait(timeout=10)
        except (subprocess.TimeoutExpired, OSError):
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        for stream in (process.stdin, process.stdout):
            if stream and not stream.closed:
                stream.close()

    # -- framing -----------------------------------------------------------

    def _send(self, payload: dict[str, Any]) -> None:
        process = self._require()
        if process.stdin is None:
            raise MCPError(f"{self.command}: server stdin is not available")
        try:
            process.stdin.write(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise MCPError(f"{self.command}: server closed its input ({exc})") from exc

    def _readline(self, timeout: int) -> bytes:
        """One newline-delimited message, with a deadline.

        The pipes are unbuffered and the line assembly happens here, because
        `select` and a buffered reader do not mix. A server is free to write a
        notification and its reply back to back, which lands in the pipe as one
        read: with a buffered reader, the first `readline` swallows both lines
        into Python's buffer and returns the first, and the next `readline` then
        blocks on a `select` for data that has already been read. The reply
        never arrives and the loop hangs with no error. Assembling lines from
        raw reads means the buffer this function owns is the only buffer there
        is, so a complete line is always available the moment it exists.
        """
        process = self._require()
        if process.stdout is None:
            raise MCPError(f"{self.command}: server stdout is not available")
        fd = process.stdout.fileno()
        deadline = time.monotonic() + timeout

        while True:
            newline = self._buffer.find(b"\n")
            if newline >= 0:
                line, self._buffer = self._buffer[:newline], self._buffer[newline + 1 :]
                if len(line) > MAX_LINE_BYTES:
                    raise MCPError(f"{self.command}: reply line exceeds {MAX_LINE_BYTES} bytes")
                return line
            if len(self._buffer) > MAX_LINE_BYTES:
                raise MCPError(f"{self.command}: reply line exceeds {MAX_LINE_BYTES} bytes")

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise MCPError(
                    f"{self.command}: no reply within {timeout}s; refusing to wait indefinitely"
                )
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                continue
            try:
                chunk = os.read(fd, _READ_CHUNK)
            except OSError as exc:
                raise MCPError(f"{self.command}: could not read from the server: {exc}") from exc
            if not chunk:
                raise MCPError(f"{self.command}: server exited without replying")
            self._buffer += chunk

    def _request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        self._next_id += 1
        request_id = self._next_id
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})

        # Skip server-initiated notifications. They are legitimate and expected
        # -- progress and logging arrive this way -- and mistaking one for our
        # reply would hang the loop on a message that is not an answer.
        while True:
            message = json.loads(self._readline(CALL_TIMEOUT_S).decode("utf-8"))
            if not isinstance(message, dict):
                raise MCPError(f"{self.command}: reply is not a JSON-RPC object")
            if message.get("id") != request_id:
                continue
            if "error" in message:
                error = message["error"] or {}
                raise MCPError(
                    f"{self.command}: {method} failed: "
                    f"{error.get('message', 'unknown error')}"
                    if isinstance(error, dict)
                    else f"{self.command}: {method} failed"
                )
            return message.get("result")

    def _notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _require(self) -> subprocess.Popen:
        if self._process is None:
            raise MCPError(f"{self.command}: server is not running")
        return self._process

    def _handshake(self) -> None:
        result = self._request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": CLIENT_NAME, "version": CLIENT_VERSION},
            },
        )
        if not isinstance(result, dict):
            raise MCPError(f"{self.command}: initialize returned nothing usable")
        self._notify("notifications/initialized")

    # -- tools -------------------------------------------------------------

    def tools(self) -> list[Tool]:
        if self._tools is not None:
            return list(self._tools.values())
        result = self._request("tools/list")
        listed = (result or {}).get("tools")
        if not isinstance(listed, list):
            raise MCPError(f"{self.command}: tools/list returned no tool array")
        found: dict[str, Tool] = {}
        for entry in listed:
            if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                raise MCPError(f"{self.command}: tools/list returned an unnamed tool")
            schema = entry.get("inputSchema")
            if not isinstance(schema, dict):
                # A tool with no schema would be advertised to the model as
                # callable with anything, and would then be invoked with
                # whatever the model felt like.
                raise MCPError(f"{self.command}: tool {entry['name']!r} has no input schema")
            schema = {k: v for k, v in schema.items() if k != "$schema"}
            found[entry["name"]] = Tool(
                name=entry["name"],
                description=str(entry.get("description") or ""),
                parameters=schema,
            )
        self._tools = found
        return list(found.values())

    def has(self, name: str) -> bool:
        return name in self.tools()

    def call(self, name: str, arguments: dict[str, Any]) -> str:
        """Run one tool and return its output as text.

        `arguments` is handed to the server unexamined. That is deliberate and
        it is not a gap: the server is the authority on its own tool's arguments
        and refuses unknown ones itself, which is the behaviour the external
        agents already depend on. Validating here as well would mean two
        schemas to keep in step, and the copy that drifts is the copy that gets
        relaxed.
        """
        self.tools()
        if name not in self._tools:
            raise ToolRefused(
                f"{self.command} has no tool named {name!r}; it offers "
                f"{', '.join(sorted(self._tools)) or 'nothing'}"
            )
        result = self._request("tools/call", {"name": name, "arguments": arguments})
        if not isinstance(result, dict):
            raise MCPError(f"{self.command}: {name} returned nothing usable")
        return _content_to_text(result, name)


def _content_to_text(result: dict[str, Any], name: str) -> str:
    """Flatten an MCP tool result into the text the model will see."""
    if result.get("isError"):
        # A tool that refused -- out of scope, no approval -- reports it here
        # rather than as a protocol error, and the model is told. That is the
        # whole point of returning refusals as text: the model can try a
        # different target, and a human still saw the refusal in the audit.
        blocks = result.get("content")
        text = _content_to_text({"content": blocks}, name)
        return f"{name} refused: {text}" if text else f"{name} refused"

    blocks = result.get("content")
    if not isinstance(blocks, list):
        raise MCPError(f"{name} returned no content array")
    parts: list[str] = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            parts.append(str(block.get("text") or ""))
        elif block.get("type") == "image":
            # A model that can see images would need the bytes on the wire,
            # which means a scan screenshot of a client host going to a third
            # party. Refusing it here keeps that decision visible instead of
            # leaving it to whichever provider happens to be configured.
            parts.append("[an image was returned, which is not sent to the provider]")
        else:
            parts.append(f"[unsupported content type {block.get('type')!r} omitted]")
    return "\n".join(parts)


@dataclass(frozen=True)
class Binding:
    """A tool, and the server that is willing to run it."""

    tool: Tool
    server: Server


def gather(servers: list[Server]) -> dict[str, Binding]:
    """Index every server's tools by name, refusing a collision.

    A duplicate name is refused rather than resolved by precedence: if two
    servers both answer to `nmap_scan`, the model cannot tell them apart, and
    picking one silently means the audit names a tool that may not be the tool
    that ran.
    """
    index: dict[str, Binding] = {}
    for server in servers:
        for tool in server.tools():
            owner = index.get(tool.name)
            if owner is not None:
                raise MCPError(
                    f"tool {tool.name!r} is offered by both {owner.server.command} and "
                    f"{server.command}; refusing to guess which one a model meant"
                )
            index[tool.name] = Binding(tool=tool, server=server)
    return index
