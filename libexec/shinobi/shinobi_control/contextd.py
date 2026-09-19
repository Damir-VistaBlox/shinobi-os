"""Dedicated read-only context service for desktop and agent consumers."""
from __future__ import annotations

import asyncio
import json
import os
import platform
import shutil
from pathlib import Path
from typing import Any

from .protocol import MAX_LINE_BYTES, ProtocolError, Request, encode, response
from .registry import _read_current_engagement, _read_user_value


def snapshot() -> dict[str, Any]:
    return {
        "session": {
            "wayland": bool(os.environ.get("WAYLAND_DISPLAY")),
            "desktop": os.environ.get("XDG_CURRENT_DESKTOP", ""),
            "live": Path("/run/live/medium/live/filesystem.squashfs").exists(),
        },
        "compositor": {
            "hyprland": bool(shutil.which("hyprctl")),
        },
        "host": {"kernel": platform.release()},
        "theme": _read_user_value("theme"),
        "engagement": _read_current_engagement(),
        "services": {
            "agentd": os.path.exists(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "shinobi/agent.sock")),
        },
    }


class ContextServer:
    def __init__(self, socket_path: Path):
        self.socket_path = socket_path
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
            if request.capability not in {"context.snapshot", "context.category"}:
                raise ProtocolError("context service only accepts context capabilities")
            value = snapshot()
            if request.capability == "context.category":
                category = request.arguments.get("category")
                if not isinstance(category, str) or category not in value:
                    raise ProtocolError("unknown context category")
                value = {category: value[category]}
            result = response(request.request_id, "completed", capability=request.capability, result=value)
        except Exception as exc:
            result = response("", "failed", error=str(exc))
        writer.write(encode(result))
        await writer.drain()
        writer.close()
        await writer.wait_closed()


async def run(socket_path: Path) -> None:
    server = ContextServer(socket_path)
    await server.start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_name in ("SIGTERM", "SIGINT"):
        import signal
        loop.add_signal_handler(getattr(signal, signal_name), stop.set)
    await stop.wait()
    await server.close()


def main() -> None:
    path = Path(os.environ.get("SHINOBI_CONTEXT_SOCKET", Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "shinobi/context.sock"))
    asyncio.run(run(path))


if __name__ == "__main__":
    main()
