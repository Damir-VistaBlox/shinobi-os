#!/usr/bin/env python3
"""A fake LLM provider: real HTTP, the real wire formats, a recorded history.

Used by tests/test-llm.sh. It speaks both the OpenAI and Anthropic request
shapes on the same listener, because the client has to be exercised against the
bytes a real provider would see rather than against a mock of our own parser.

It also does the things a real endpoint does that matter to a security test:

  * it serves whatever port it was told to, so a manifest can point at it;
  * it can be told to answer with a redirect, so the client's refusal to follow
    one is tested against an actual 302 and not a hypothetical;
  * it can be told to answer from a *different* port than the one the client
    connected to, which is how the connected-peer check gets tested;
  * it records every request body it was sent, so a test can assert on what
    actually went out -- which is the only way to check that a prompt did, or
    did not, leave.

Environment:
  FAKE_PORT_FILE   write the listening port here once bound
  FAKE_HISTORY     append each request as one JSON line here
  FAKE_MODE        openai | anthropic | redirect | boom
  FAKE_REDIRECT_TO absolute URL to answer a redirect with
"""
from __future__ import annotations

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE = os.environ["FAKE_PORT_FILE"]
HISTORY = os.environ["FAKE_HISTORY"]
MODE = os.environ.get("FAKE_MODE", "openai")
REDIRECT_TO = os.environ.get("FAKE_REDIRECT_TO", "")

# Scripted turns, so a test can drive a tool call and then a final answer.
# One JSON document per turn, as sent on stdin after the mode line.
SCRIPT: list[dict] = []


def record(entry: dict) -> None:
    with open(HISTORY, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args) -> None:  # keep the test output clean
        return

    def do_POST(self) -> None:  # noqa: N802 - stdlib interface
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = {"_unparseable": raw.decode("utf-8", "replace")}

        record(
            {
                "path": self.path,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body,
            }
        )

        if MODE == "redirect":
            self.send_response(302)
            self.send_header("Location", REDIRECT_TO)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if MODE == "boom":
            payload = json.dumps({"error": {"message": "upstream is on fire"}}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if MODE == "anthropic" or self.path.endswith("/messages"):
            payload = json.dumps(_anthropic_turn(body)).encode()
        else:
            payload = json.dumps(_openai_turn(body)).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 - stdlib interface
        # A redirect target that answers at all is the finding: the client was
        # supposed to refuse before opening this connection.
        record({"path": self.path, "method": "GET", "body": None})
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


def _next_scripted(api: str, body: dict) -> dict:
    """Take the next scripted turn, or answer plainly."""
    if SCRIPT:
        turn = SCRIPT.pop(0)
        if turn.get("error"):
            return turn
        if api == "anthropic":
            return {
                "content": _anthropic_blocks(turn),
                "stop_reason": "tool_use" if turn.get("tool") else "end_turn",
                "usage": {"input_tokens": 11, "output_tokens": 7},
            }
        message: dict = {"role": "assistant", "content": turn.get("text", "")}
        if turn.get("tool"):
            message["tool_calls"] = [
                {
                    "id": turn.get("id", "call_1"),
                    "type": "function",
                    # The real format delivers arguments as a JSON *string*,
                    # which is the detail the client has to get right.
                    "function": {
                        "name": turn["tool"],
                        "arguments": json.dumps(turn.get("arguments", {})),
                    },
                }
            ]
        return {
            "choices": [
                {
                    "message": message,
                    "finish_reason": "tool_calls" if turn.get("tool") else "stop",
                }
            ],
            "usage": {"prompt_tokens": 11, "completion_tokens": 7},
        }
    return {}


def _anthropic_blocks(turn: dict) -> list[dict]:
    blocks: list[dict] = []
    if turn.get("text"):
        blocks.append({"type": "text", "text": turn["text"]})
    if turn.get("tool"):
        blocks.append(
            {
                "type": "tool_use",
                "id": turn.get("id", "call_1"),
                "name": turn["tool"],
                # Anthropic delivers arguments as an object, not a string.
                "input": turn.get("arguments", {}),
            }
        )
    return blocks


def _openai_turn(body: dict) -> dict:
    if not body.get("messages"):
        # An empty conversation is a client bug worth surfacing loudly.
        return {"error": {"message": "no messages"}}
    turn = _next_scripted("openai", body)
    if turn.get("error"):
        return {"error": {"message": turn["error"]}}
    return turn or {
        "choices": [
            {"message": {"role": "assistant", "content": "nothing was scripted"}, "finish_reason": "stop"}
        ],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1},
    }


def _anthropic_turn(body: dict) -> dict:
    turn = _next_scripted("anthropic", body)
    if turn.get("error"):
        return {"error": {"message": turn["error"]}}
    return turn or {
        "content": [{"type": "text", "text": "nothing was scripted"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


def main() -> None:
    # The script arrives on stdin as a single JSON document: an array of turns
    # to play in order, or one turn.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        parsed = json.loads(line)
        SCRIPT.extend(parsed if isinstance(parsed, list) else [parsed])

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    with open(PORT_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    sys.stderr.write(f"fake provider on 127.0.0.1:{port} mode={MODE}\n")
    sys.stderr.flush()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        thread.join()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
