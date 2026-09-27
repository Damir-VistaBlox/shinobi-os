"""The three provider wire formats, and the one internal form they map to.

The internal form is deliberately dull: a list of dicts with `role`, `text`,
and for tool traffic an `id`, a `name`, and `arguments`. Every provider
difference -- where the system prompt lives, whether tool arguments arrive as a
JSON string or a nested object, whether a tool result is a `tool` role or a
`user` turn wearing a disguise -- is contained in this file, so the loop that
drives the conversation does not know which API it is talking to.

Two conversions here are not cosmetic:

  * OpenAI delivers tool arguments as a *string* that has to be parsed, and
    Anthropic delivers them as an object. A provider can also send a string
    that is not JSON, or an object where a string was promised. Both are
    refused here rather than passed on as a string, because the alternative is
    that a malformed argument reaches a tool and is either silently dropped or
    executed as something nobody approved.

  * Anthropic requires the conversation to alternate roles, and requires tool
    results to arrive inside a `user` turn. A conversation built by a tool loop
    has consecutive tool results, so they are batched. Skipping that produces a
    400 from a provider, which looks like a client bug and is not obviously one.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

# Anthropic requires an explicit output cap; OpenAI does not. This is a ceiling
# on a single reply, not a budget for the conversation.
DEFAULT_MAX_TOKENS = 4096


class WireError(RuntimeError):
    """A provider's reply could not be understood, or reported a failure.

    `status` is kept separate from `message` because they are treated
    differently downstream: the status goes to the audit trail, the message goes
    to the operator's terminal. A provider's error text can quote the request
    back at us, and the request is the prompt, so it has no business in a log.
    """

    def __init__(self, message: str, *, status: int = 0) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class ToolCall:
    """A request from the model to run one of our tools."""

    id: str
    name: str
    arguments: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class Reply:
    """One assistant turn: text, tool calls, or both."""

    text: str = ""
    tool_calls: tuple[ToolCall, ...] = ()
    stop_reason: str = ""
    input_tokens: int = 0
    output_tokens: int = 0

    @property
    def wants_tools(self) -> bool:
        return bool(self.tool_calls)


# --------------------------------------------------------------------------
# Internal form
# --------------------------------------------------------------------------


def user(text: str) -> dict[str, Any]:
    return {"role": "user", "text": text}


def assistant(text: str = "", tool_calls: tuple[ToolCall, ...] = ()) -> dict[str, Any]:
    return {"role": "assistant", "text": text, "tool_calls": list(tool_calls)}


def tool_result(call: ToolCall, text: str) -> dict[str, Any]:
    return {"role": "tool", "id": call.id, "name": call.name, "text": text}


def system_message(text: str) -> dict[str, Any]:
    return {"role": "system", "text": text}


def to_json_form(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Project the internal form onto plain JSON.

    The internal form carries `ToolCall` objects so the loop can hand them
    around, but a digest is computed over JSON and a dataclass does not
    serialise. This is the one projection both the digest and the wire format
    go through, which is deliberate: the thing that is hashed and the thing that
    is sent are then the same bytes by construction rather than by two functions
    agreeing to be careful.
    """
    out: list[dict[str, Any]] = []
    for message in messages:
        entry: dict[str, Any] = {"role": message["role"]}
        if message.get("text") is not None:
            entry["text"] = message["text"]
        if message["role"] == "tool":
            entry["id"] = message["id"]
            entry["name"] = message["name"]
        if message.get("tool_calls"):
            # Idempotent: a caller holding the plain form already gets it back
            # unchanged, rather than having to reconstruct dataclasses to hash
            # a conversation it built as dictionaries.
            entry["tool_calls"] = [
                call
                if isinstance(call, dict)
                else {"id": call.id, "name": call.name, "arguments": call.arguments}
                for call in message["tool_calls"]
            ]
        out.append(entry)
    return out


# --------------------------------------------------------------------------
# Request building
# --------------------------------------------------------------------------


def _openai_messages(system: str, messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if system:
        out.append({"role": "system", "content": system})
    for message in messages:
        role = message["role"]
        if role == "user":
            out.append({"role": "user", "content": message["text"]})
        elif role == "assistant":
            entry: dict[str, Any] = {"role": "assistant", "content": message.get("text") or None}
            calls = message.get("tool_calls") or []
            if calls:
                entry["tool_calls"] = [
                    {
                        "id": call["id"],
                        "type": "function",
                        "function": {
                            "name": call["name"],
                            # A string, per the format. The reverse direction
                            # parses it, and refuses it if it is not JSON.
                            "arguments": json.dumps(call["arguments"], separators=(",", ":")),
                        },
                    }
                    for call in calls
                ]
            out.append(entry)
        elif role == "tool":
            out.append(
                {
                    "role": "tool",
                    "tool_call_id": message["id"],
                    "content": message["text"],
                }
            )
        else:
            raise WireError(f"internal: cannot send a {role!r} message to an OpenAI provider")
    return out


def _anthropic_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Fold the internal form into Anthropic's stricter alternation rules.

    Consecutive tool results become one `user` turn, because Anthropic carries
    them as `tool_result` blocks inside a user message and will reject two user
    turns in a row.
    """
    out: list[dict[str, Any]] = []
    pending: list[dict[str, Any]] = []

    def flush() -> None:
        if pending:
            out.append({"role": "user", "content": list(pending)})
            pending.clear()

    for message in messages:
        role = message["role"]
        if role == "tool":
            pending.append(
                {
                    "type": "tool_result",
                    "tool_use_id": message["id"],
                    "content": message["text"],
                }
            )
            continue
        flush()
        if role == "user":
            out.append({"role": "user", "content": [{"type": "text", "text": message["text"]}]})
        elif role == "assistant":
            blocks: list[dict[str, Any]] = []
            if message.get("text"):
                blocks.append({"type": "text", "text": message["text"]})
            for call in message.get("tool_calls") or []:
                blocks.append(
                    {
                        "type": "tool_use",
                        "id": call["id"],
                        "name": call["name"],
                        "input": call["arguments"],
                    }
                )
            # An assistant turn with neither text nor a tool call is not a
            # message; sending one empty block is a 400 from the provider.
            if blocks:
                out.append({"role": "assistant", "content": blocks})
        else:
            raise WireError(f"internal: cannot send a {role!r} message to an Anthropic provider")
    flush()

    if out and out[0]["role"] != "user":
        out.insert(0, {"role": "user", "content": [{"type": "text", "text": "(continue)"}]})
    return out


def build(
    provider_api: str,
    model: str,
    system: str,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]],
    *,
    max_tokens: int = DEFAULT_MAX_TOKENS,
) -> tuple[str, dict[str, Any]]:
    """Return the request path and body for one provider API."""
    messages = to_json_form(messages)

    if provider_api in {"openai", "openai-compatible"}:
        body: dict[str, Any] = {
            "model": model,
            "messages": _openai_messages(system, messages),
        }
        if tools:
            body["tools"] = [
                {
                    "type": "function",
                    "function": {
                        "name": tool["name"],
                        "description": tool.get("description", ""),
                        "parameters": tool["parameters"],
                    },
                }
                for tool in tools
            ]
        return "/chat/completions", body

    if provider_api == "anthropic":
        body = {
            "model": model,
            "max_tokens": max_tokens,
            "messages": _anthropic_messages(messages),
        }
        if system:
            body["system"] = system
        if tools:
            body["tools"] = [
                {
                    "name": tool["name"],
                    "description": tool.get("description", ""),
                    "input_schema": tool["parameters"],
                }
                for tool in tools
            ]
        return "/messages", body

    raise WireError(f"no wire format for api {provider_api!r}")


# --------------------------------------------------------------------------
# Reply parsing
# --------------------------------------------------------------------------


def _provider_error(status: int, body: Any) -> WireError:
    """Turn a provider's error body into a WireError with a quoted reason."""
    detail = ""
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict):
            detail = str(error.get("message", ""))
        elif isinstance(error, str):
            detail = error
        elif isinstance(body.get("message"), str):
            detail = body["message"]
    if not detail:
        detail = f"HTTP {status}"
    return WireError(detail[:500], status=status)


def _tool_arguments(raw: Any, *, where: str) -> dict[str, Any]:
    """Accept a tool's arguments only in a form we can execute.

    A provider that sends a JSON string must send valid JSON; one that sends an
    object must send an object. Anything else is refused rather than coerced,
    because this is the boundary where a model's intent becomes a command line.
    """
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise WireError(f"{where}: tool arguments are not valid JSON") from exc
        if not isinstance(parsed, dict):
            raise WireError(f"{where}: tool arguments decoded to {type(parsed).__name__}, not an object")
        return parsed
    if raw is None:
        return {}
    raise WireError(f"{where}: tool arguments are {type(raw).__name__}, expected an object or a JSON string")


def parse(provider_api: str, status: int, body: Any) -> Reply:
    """Read one assistant turn out of a provider's reply."""
    if isinstance(body, dict) and body.get("error"):
        raise _provider_error(status, body)
    if status >= 400:
        raise _provider_error(status, body)
    if not isinstance(body, dict):
        raise WireError(f"provider returned a {type(body).__name__}, expected an object")

    if provider_api in {"openai", "openai-compatible"}:
        return _parse_openai(body)
    if provider_api == "anthropic":
        return _parse_anthropic(body)
    raise WireError(f"no wire format for api {provider_api!r}")


def _parse_openai(body: dict[str, Any]) -> Reply:
    choices = body.get("choices")
    if not isinstance(choices, list) or not choices:
        raise WireError("provider returned no choices")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise WireError("provider returned a choice with no message")

    calls: list[ToolCall] = []
    for index, raw in enumerate(message.get("tool_calls") or []):
        if not isinstance(raw, dict):
            raise WireError(f"tool call {index} is not an object")
        function = raw.get("function")
        if not isinstance(function, dict) or not isinstance(function.get("name"), str):
            raise WireError(f"tool call {index} has no function name")
        call_id = raw.get("id")
        if not isinstance(call_id, str) or not call_id:
            raise WireError(f"tool call {index} has no id to correlate its result with")
        calls.append(
            ToolCall(
                id=call_id,
                name=function["name"],
                arguments=_tool_arguments(
                    function.get("arguments"), where=f"tool call {function['name']!r}"
                ),
            )
        )

    usage = body.get("usage") or {}
    return Reply(
        text=str(message.get("content") or ""),
        tool_calls=tuple(calls),
        stop_reason=str(choices[0].get("finish_reason") or ""),
        input_tokens=int(usage.get("prompt_tokens") or 0),
        output_tokens=int(usage.get("completion_tokens") or 0),
    )


def _parse_anthropic(body: dict[str, Any]) -> Reply:
    blocks = body.get("content")
    if not isinstance(blocks, list):
        raise WireError("provider returned no content blocks")

    text_parts: list[str] = []
    calls: list[ToolCall] = []
    for index, block in enumerate(blocks):
        if not isinstance(block, dict):
            raise WireError(f"content block {index} is not an object")
        kind = block.get("type")
        if kind == "text":
            text_parts.append(str(block.get("text") or ""))
        elif kind == "tool_use":
            call_id = block.get("id")
            name = block.get("name")
            if not isinstance(call_id, str) or not call_id:
                raise WireError(f"tool_use block {index} has no id")
            if not isinstance(name, str) or not name:
                raise WireError(f"tool_use block {index} has no name")
            calls.append(
                ToolCall(
                    id=call_id,
                    name=name,
                    arguments=_tool_arguments(block.get("input"), where=f"tool call {name!r}"),
                )
            )
        # "thinking" and "redacted_thinking" blocks are ignored on purpose: they
        # are the provider's own reasoning, not our tools.

    usage = body.get("usage") or {}
    return Reply(
        text="".join(text_parts),
        tool_calls=tuple(calls),
        stop_reason=str(body.get("stop_reason") or ""),
        input_tokens=int(usage.get("input_tokens") or 0),
        output_tokens=int(usage.get("output_tokens") or 0),
    )
