"""Shinobi agent control daemon with a restricted Unix-socket protocol."""
from __future__ import annotations

import asyncio
import json
import os
import signal
from pathlib import Path
from typing import Any

from .audit import write as audit_write
from .policy import allowed, current_profile
from .protocol import MAX_LINE_BYTES, ProtocolError, Request, encode, response
from .registry import builtin_capabilities, describe


class AgentDaemon:
    def __init__(self, socket_path: Path):
        self.socket_path = socket_path
        self.capabilities = builtin_capabilities()
        self.server: asyncio.AbstractServer | None = None

    async def start(self) -> None:
        self.socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        self.server = await asyncio.start_unix_server(self.handle, path=str(self.socket_path))
        os.chmod(self.socket_path, 0o600)

    async def close(self) -> None:
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            line = await reader.readline()
            if not line or len(line) > MAX_LINE_BYTES:
                raise ProtocolError("request exceeds maximum size")
            request = Request.from_line(line)
            result = await self.dispatch(request)
        except ProtocolError as exc:
            result = response("", "failed", error=str(exc))
        except Exception as exc:  # daemon boundary: never leak a traceback to clients
            result = response("", "failed", error=f"internal error: {exc}")
        writer.write(encode(result))
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    async def dispatch(self, request: Request) -> dict[str, Any]:
        if request.capability == "agent.status":
            return response(request.request_id, "completed", result={"profile": current_profile(), "socket": str(self.socket_path)})
        if request.capability == "agent.capabilities":
            return response(request.request_id, "completed", result=describe(self.capabilities))
        capability = self.capabilities.get(request.capability)
        if capability is None:
            audit_id = audit_write(actor="agent", capability=request.capability, arguments=request.arguments, status="denied", detail="unknown capability", request_id=request.request_id)
            return response(request.request_id, "denied", audit_id=audit_id, error="unknown capability")
        ok, reason = allowed(capability)
        if not ok:
            audit_id = audit_write(actor="agent", capability=request.capability, arguments=request.arguments, status="denied", detail=reason, request_id=request.request_id)
            return response(request.request_id, "approval-required" if "approval" in reason else "denied", audit_id=audit_id, error=reason)
        try:
            result = await asyncio.wait_for(asyncio.to_thread(capability.handler, request.arguments), timeout=capability.timeout)
        except Exception as exc:
            audit_id = audit_write(actor="agent", capability=request.capability, arguments=request.arguments, status="failed", detail=str(exc), request_id=request.request_id)
            return response(request.request_id, "failed", audit_id=audit_id, error=str(exc))
        audit_id = audit_write(actor="agent", capability=request.capability, arguments=request.arguments, status="completed", request_id=request.request_id)
        return response(request.request_id, "completed", capability=request.capability, result=result, audit_id=audit_id)


async def run(socket_path: Path) -> None:
    daemon = AgentDaemon(socket_path)
    await daemon.start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    await daemon.close()


def main() -> None:
    socket_path = Path(os.environ.get("SHINOBI_AGENT_SOCKET", Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "shinobi/agent.sock"))
    asyncio.run(run(socket_path))


if __name__ == "__main__":
    main()
