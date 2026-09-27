"""The conversation loop, and the per-turn approval it needs.

The single most important thing in this file is that **every turn is separately
approved**. It is easy to write a tool loop that asks the gate once, on turn
one, and then keeps talking to the provider for the rest of the run. That would
be wrong here, and specifically so:

Turn one usually carries the operator's own words. Turn two carries whatever the
tools returned -- an nmap port list, a `whatweb` fingerprint, a DNS answer --
appended to those words, and that output is client-confidential by construction.
It is the whole reason the engagement exists. So the moment a tool result enters
the conversation, the thing being sent has changed, and an approval granted for
the earlier text is an approval for text nobody read.

The digest is therefore computed over the entire request -- system prompt,
every message, and the tool schemas -- and not over the operator's prompt. An
approval is spent the instant the conversation grows past it, and the operator
sees a *new* digest at each turn, which is the honest thing to show them: this
is what is about to leave, and it is not the same thing as last time.

What the operator gets is a digest, a provider, a model, and a turn number. What
they never get is the text, because the approval file and both audit trails
store the digest and nothing else.
"""
from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Callable, TextIO

from .. import approval as approval_store
from .. import credentials, egress
from ..policy import current_profile
from . import mcp, transport, wire
from .wire import ToolCall

# A run that has not converged in this many turns is a loop, not a
# conversation. Refusing beats spending approvals forever.
DEFAULT_MAX_TURNS = 8

# One turn asking for a dozen tools is not a plan, it is a model that has lost
# the thread, and each one is a separate governed call.
MAX_TOOL_CALLS_PER_TURN = 8

APPROVAL_TTL_S = 600
APPROVAL_POLL_S = 1.0

DEFAULT_SYSTEM = (
    "You are assisting a Shinobi penetration test engagement. Use the provided "
    "tools to answer questions about the authorized target. Every tool is checked "
    "against the engagement's scope: a refusal means that target is not in scope, "
    "and you should say so rather than trying to work around it."
)


class LoopRefused(RuntimeError):
    """The conversation could not continue, and no request was sent."""


@dataclass
class Result:
    text: str = ""
    turns: int = 0
    tool_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    digests: list[str] = field(default_factory=list)

    def summary(self) -> str:
        bits = [f"{self.turns} turn(s)"]
        if self.tool_calls:
            bits.append(f"{self.tool_calls} tool call(s)")
        if self.input_tokens or self.output_tokens:
            bits.append(f"{self.input_tokens} in / {self.output_tokens} out tokens")
        return ", ".join(bits)


def request_digest(system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> str:
    """Digest the request that is about to be sent, not the words that started it.

    Delegates to the gate's own digest so there is one definition of what a
    prompt hashes to, shared by the thing that computes it here, the thing that
    checks it there, and the thing an operator compares when they are deciding.
    """
    return egress.prompt_digest(_canonical_request(system, messages, tools))


def _canonical_request(system: str, messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> str:
    """The exact request, as one canonical string.

    Sorted keys and no whitespace, so the same request always produces the same
    bytes and therefore the same digest. That is what makes an approval
    spendable: if this were allowed to vary, a human would approve a digest that
    no longer matched by the time the gate checked it.
    """
    return json.dumps(
        {
            "v": 1,
            "system": system,
            "messages": wire.to_json_form(messages),
            "tools": tools,
        },
        sort_keys=True,
        separators=(",", ":"),
    )


# --------------------------------------------------------------------------
# Approvals
# --------------------------------------------------------------------------


def interactive_approver(
    *,
    wait: bool = True,
    timeout: int = APPROVAL_TTL_S,
    stream: TextIO | None = None,
) -> Callable[[str, str, str, int], str | None]:
    """Build an approver that asks a human, once per turn.

    Returns the approval id, or None if the human said no. A conversation cannot
    be pre-approved in advance, because the digest that turn two needs does not
    exist until turn one's tools have run -- so the only honest interface is to
    stop and ask. `wait=False` requests and returns immediately, which is the
    shape an operator driving this from two terminals wants.
    """
    out = stream if stream is not None else sys.stderr

    def approve(digest: str, provider: str, model: str, turn: int) -> str | None:
        record = approval_store.create(
            capability=egress.EGRESS_CAPABILITY,
            arguments={"prompt_sha256": digest, "provider": provider, "model": model},
            profile=current_profile(),
            reason=f"LLM turn {turn} to {provider}/{model}",
            ttl_seconds=timeout,
        )
        approval_id = record["approval_id"]
        print(
            f"approval {approval_id} requested for turn {turn}: "
            f"prompt {digest[:16]}... to {provider}/{model}\n"
            f"  the text is not shown and is not stored. Review what the tools "
            f"returned, then: shinobi approval approve {approval_id}",
            file=out,
        )
        if not wait:
            return None

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                state = approval_store.get(approval_id).get("state")
            except (FileNotFoundError, ValueError):
                return None
            if state == "approved":
                return approval_id
            if state in {"denied", "cancelled"}:
                print(f"approval {approval_id} was {state}", file=out)
                return None
            time.sleep(APPROVAL_POLL_S)
        print(f"approval {approval_id} timed out after {timeout}s", file=out)
        return None

    return approve


# --------------------------------------------------------------------------
# The loop
# --------------------------------------------------------------------------


def _tools_for(index: dict[str, mcp.Binding]) -> list[dict[str, Any]]:
    """The tool schemas to advertise, in a stable order.

    Sorted so that the same conversation digests the same way twice: an approval
    is bound to a digest, and a digest that changed because a dict iterated in a
    different order would be an approval that mysteriously stopped matching.
    """
    return [index[name].tool.as_openai() for name in sorted(index)]


def run(
    provider_id: str,
    prompt: str,
    *,
    model: str | None = None,
    system: str | None = DEFAULT_SYSTEM,
    servers: list[mcp.Server] | None = None,
    max_turns: int = DEFAULT_MAX_TURNS,
    approve: Callable[[str, str, str, int], str | None] | None = None,
    timeout: int = transport.TIMEOUT_S,
    max_tokens: int = wire.DEFAULT_MAX_TOKENS,
    stream: TextIO | None = None,
) -> Result:
    """Run one governed conversation to a final answer.

    `servers` are entered and left by the caller, so a caller that wants tools
    available for several conversations pays the startup once.
    """
    out = stream if stream is not None else sys.stderr
    if max_turns < 1:
        raise LoopRefused("max_turns must be at least 1")

    # Only servers this call started are exited here. A caller that entered its
    # own -- to amortise startup across several conversations, as the docstring
    # invites -- keeps ownership, and re-entering would spawn a second process
    # and orphan the first.
    entered = [server for server in (servers or []) if not server.started]
    try:
        for server in entered:
            server.__enter__()
        index = mcp.gather(servers) if servers else {}

        if index:
            print(f"  tools: {', '.join(sorted(index))}", file=out)
        else:
            print("  tools: none (a plain question, with no tool access)", file=out)

        tools = _tools_for(index)
        system_text = system or ""
        messages: list[dict[str, Any]] = [wire.user(prompt)]
        result = Result()
        resolved_model = model

        for turn in range(1, max_turns + 1):
            canonical = _canonical_request(system_text, messages, tools)
            digest = request_digest(system_text, messages, tools)
            result.digests.append(digest)

            approval_id = ""
            if approve is not None:
                # The approval is bound to the model, so the model has to be
                # settled before a human is asked. Asking for "the default" and
                # letting the gate resolve it afterwards is a mismatch the gate
                # refuses, and an operator reads that as the approval being
                # broken rather than as a prompt to be more careful.
                bound_model = egress.effective_model(provider_id, resolved_model)
                granted = approve(digest, provider_id, bound_model, turn)
                if not granted:
                    raise LoopRefused(
                        f"turn {turn} was not approved, so nothing further was sent. "
                        "The conversation so far was not transmitted."
                    )
                approval_id = granted

            # The gate is asked with the whole request as the prompt. It hashes
            # what it is given, so this is the text the approval above was bound
            # to -- not a summary of it.
            decision = egress.authorize(
                provider_id,
                canonical,
                model=resolved_model,
                system=None,
                approval_id=approval_id or None,
            )
            resolved_model = decision.model

            api_key = ""
            if decision.requires_key:
                try:
                    api_key = credentials.get_key(decision.provider.id)
                except Exception as exc:  # noqa: BLE001 - never leak broker detail
                    egress.finish(decision, ok=False, detail=f"credential broker: {type(exc).__name__}")
                    raise LoopRefused(
                        f"no usable API key for {decision.provider.id} ({type(exc).__name__})"
                    ) from None

            path, body = wire.build(
                decision.provider.api,
                decision.model,
                system_text,
                messages,
                tools,
                max_tokens=max_tokens,
            )
            url_path = decision.provider.base_url.rstrip("/") + path

            try:
                response = transport.post(
                    decision, url_path, body, api_key=api_key, timeout=timeout
                )
            except transport.TransportRefused as exc:
                # A refusal here is a security decision, and it is recorded as
                # one. The message is safe to log: it is ours, not the
                # provider's, and it describes addresses rather than content.
                egress.finish(decision, ok=False, detail=f"refused: {exc}")
                raise
            except transport.TransportError as exc:
                egress.finish(decision, ok=False, detail=f"transport: {type(exc).__name__}")
                raise

            try:
                reply = wire.parse(decision.provider.api, response.status, response.json())
            except wire.WireError as exc:
                # Status only. The provider's message can quote the request,
                # and the request is the prompt.
                egress.finish(decision, ok=False, detail=f"http {response.status}: {type(exc).__name__}")
                raise

            egress.finish(
                decision,
                ok=True,
                detail=(
                    f"http {response.status} turn={turn} "
                    f"tokens={reply.input_tokens}/{reply.output_tokens}"
                    f"{' tools=' + ','.join(c.name for c in reply.tool_calls) if reply.tool_calls else ''}"
                ),
            )
            result.turns = turn
            result.input_tokens += reply.input_tokens
            result.output_tokens += reply.output_tokens

            if not reply.wants_tools:
                result.text = reply.text
                return result

            if len(reply.tool_calls) > MAX_TOOL_CALLS_PER_TURN:
                raise LoopRefused(
                    f"turn {turn} asked for {len(reply.tool_calls)} tool calls at once, "
                    f"more than the {MAX_TOOL_CALLS_PER_TURN} allowed; refusing to run them"
                )

            messages.append(wire.assistant(reply.text, reply.tool_calls))
            for call in reply.tool_calls:
                messages.append(wire.tool_result(call, _run_tool(index, call, out)))
            result.tool_calls += len(reply.tool_calls)

        raise LoopRefused(
            f"no final answer after {max_turns} turns; refusing to keep going. "
            "The conversation was not transmitted beyond the turns approved for it."
        )
    finally:
        for server in reversed(entered):
            server.__exit__(None, None, None)


def _run_tool(index: dict[str, mcp.Binding], call: ToolCall, out: TextIO) -> str:
    """Run one tool the model asked for, and return its output as text."""
    binding = index.get(call.name)
    if binding is None:
        # Said to the model rather than raised: an invented tool name is a
        # recoverable mistake, and the model can correct it on the next turn.
        return f"no tool named {call.name!r} is available; do not call it again"
    print(f"  turn: {call.name}({_describe(call.arguments)})", file=out)
    try:
        return binding.server.call(call.name, call.arguments)
    except mcp.ToolRefused as exc:
        return str(exc)
    # A server that has crashed or misbehaved is not something to retry inside
    # the loop: the next call would fail the same way, and a broken tool server
    # is worth stopping for.


def _describe(arguments: dict[str, Any]) -> str:
    """A short, log-safe rendering of a tool call's arguments.

    Targets and tool arguments are engagement data. This goes to the operator's
    terminal, which is already engagement-local, and never to a log or to the
    provider.
    """
    parts = []
    for key, value in sorted(arguments.items()):
        text = str(value)
        if len(text) > 60:
            text = text[:57] + "..."
        parts.append(f"{key}={text}")
    return ", ".join(parts)
