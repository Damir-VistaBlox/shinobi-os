"""Optional D-Bus adapter for the agent broker.

When dbus-next is installed this exposes the same AgentDaemon dispatcher as the
Unix socket. Minimal/live images can omit the binding and retain the socket.
"""
from __future__ import annotations

from typing import Any

from .protocol import Request

try:
    from dbus_next.aio import MessageBus
    from dbus_next.service import ServiceInterface, method, signal
except ImportError:
    MessageBus = None  # type: ignore[assignment,misc]
    ServiceInterface = object  # type: ignore[assignment,misc]

    def method(*args: Any, **kwargs: Any):  # type: ignore[no-untyped-def]
        return lambda function: function

    def signal(*args: Any, **kwargs: Any):  # type: ignore[no-untyped-def]
        return lambda function: function


class AgentInterface(ServiceInterface):
    def __init__(self, daemon: Any):
        super().__init__("org.shinobi.Agent1")
        self.daemon = daemon

    @method()
    async def GetStatus(self) -> "a{sv}":
        result = await self.daemon.dispatch(Request("dbus-status", "agent.status", {}))
        return result.get("result", {})

    @method()
    async def ListCapabilities(self) -> "aa{sv}":
        result = await self.daemon.dispatch(Request("dbus-capabilities", "agent.capabilities", {}))
        return result.get("result", [])

    @method()
    async def Request(self, capability: "s", arguments: "a{sv}") -> "a{sv}":
        return await self.daemon.dispatch(Request("dbus-request", capability, dict(arguments)))

    @signal()
    def RequestChanged(self, request_id: "s", status: "s") -> "ss":
        return [request_id, status]


async def attach(daemon: Any) -> Any:
    if MessageBus is None:
        return None
    bus = await MessageBus().connect()
    await bus.request_name("org.shinobi.Agent")
    bus.export("/org/shinobi/Agent", AgentInterface(daemon))
    return bus
