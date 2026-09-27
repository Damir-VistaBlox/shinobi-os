"""Wire protocol and validation helpers for Shinobi agent requests."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 64 * 1024
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class Request:
    request_id: str
    capability: str
    arguments: dict[str, Any]
    protocol: int = PROTOCOL_VERSION

    @classmethod
    def from_mapping(cls, value: Any) -> "Request":
        if not isinstance(value, dict):
            raise ProtocolError("request must be a JSON object")
        if value.get("protocol", PROTOCOL_VERSION) != PROTOCOL_VERSION:
            raise ProtocolError("unsupported protocol version")
        request_id = value.get("request_id")
        capability = value.get("capability")
        arguments = value.get("arguments", {})
        if not isinstance(request_id, str) or not REQUEST_ID_RE.fullmatch(request_id):
            raise ProtocolError("invalid request_id")
        if not isinstance(capability, str) or not re.fullmatch(r"[a-z0-9]+(?:[._-][a-z0-9]+)*", capability):
            raise ProtocolError("invalid capability")
        if not isinstance(arguments, dict):
            raise ProtocolError("arguments must be an object")
        return cls(request_id=request_id, capability=capability, arguments=arguments)

    @classmethod
    def from_line(cls, line: bytes) -> "Request":
        if len(line) > MAX_LINE_BYTES:
            raise ProtocolError("request exceeds maximum size")
        try:
            value = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProtocolError("invalid JSON request") from exc
        return cls.from_mapping(value)


def response(request_id: str, status: str, **fields: Any) -> dict[str, Any]:
    result: dict[str, Any] = {
        "protocol": PROTOCOL_VERSION,
        "request_id": request_id,
        "status": status,
    }
    result.update(fields)
    return result


def encode(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
