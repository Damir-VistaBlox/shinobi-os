"""The only code in this project that opens a connection to an LLM provider.

The gate decides *whether* a prompt may be sent. That decision names a
provider, and a provider names a hostname, and a hostname is a claim rather
than a fact. This module is where the claim gets checked against the thing
that actually answered.

Three things here exist because of how a DNS rebind works, and they are the
whole reason this is not a two-line `urllib.request.urlopen`:

  * The connection is pinned to an address the gate already resolved. Giving
    `http.client` a hostname would make it resolve the name a second time, and
    the second answer is the one an attacker controls. So the socket is opened
    to a literal address while `Host:` and TLS `server_hostname` still carry the
    name, which is what curl calls `--resolve`.

  * The peer is read back off the socket afterwards and checked again. Pinning
    removes the window between check and connect, and this removes any doubt
    about whether pinning did what it claims. Two independent checks, because
    this is the check that stands between a cleared cloud send and reading
    instance metadata.

  * Redirects are refused rather than followed. A redirect would send the
    prompt and the API key to a host that was never resolved, never checked,
    and never approved -- and unlike the recon HTTP client, which re-checks
    each hop against the engagement's *targets*, there is no second chance
    here: the approval is bound to this provider and these arguments, and a
    302 to somewhere else is simply a different destination. No legitimate LLM
    endpoint redirects; one that does is a misconfiguration an operator should
    see rather than have papered over.

One connection carries one request. Keep-alive is not used, deliberately: a
reused socket would be reached through a peer check that already happened,
which is precisely the shortcut this file exists to close.
"""
from __future__ import annotations

import http.client
import ipaddress
import json
import socket
import ssl
from dataclasses import dataclass

from .. import egress
from ..egress import EgressRefused

TIMEOUT_S = 120
USER_AGENT = "ShinobiOS/1"
ANTHROPIC_VERSION = "2023-06-01"

# A completion is text. A provider that streams gigabytes at a client that is
# holding the whole conversation in memory is either broken or hostile, and the
# difference does not matter: this process would be the one that dies.
MAX_RESPONSE_BYTES = 8 * 1024 * 1024

# Enough for the socket to give up on a peer that accepts and then stalls,
# which is the shape of a tarpit rather than a slow model.
_READ_CHUNK = 64 * 1024


class TransportRefused(RuntimeError):
    """A request was refused before any prompt left the process.

    Distinct from TransportError so the caller can record a refusal in the audit
    trail as a refusal, rather than as a network hiccup.
    """


class TransportError(RuntimeError):
    """The request could not be completed: refused, failed, or unparseable."""


@dataclass(frozen=True)
class Response:
    status: int
    headers: dict[str, str]
    body: bytes

    def json(self) -> object:
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise TransportError(
                f"provider returned {self.status} with a body that is not JSON "
                f"({len(self.body)} bytes)"
            ) from exc


def _normalise(address: str) -> str:
    """Canonical text form of an address, so comparisons are not textual.

    `::1` and `0:0:0:0:0:0:0:1` are the same socket. Comparing strings would let
    a peer check pass on one spelling and fail on another, and which one you got
    is decided by the resolver, not by us.
    """
    try:
        return str(ipaddress.ip_address(address))
    except ValueError:
        return address


class _PinnedHTTPConnection(http.client.HTTPConnection):
    """A connection whose socket goes to a literal address we already vetted.

    `self.host` stays the *name*, because that is what `Host:` must say and
    what a virtual host routes on. Only the socket destination is replaced.
    """

    def __init__(self, host: str, address: str, port: int, timeout: int) -> None:
        super().__init__(host, port=port, timeout=timeout)
        self.address = address

    def connect(self) -> None:  # noqa: D102 - stdlib interface
        if self._tunnel_host:
            raise TransportError("proxies are not supported for provider egress")
        self.sock = socket.create_connection(
            (self.address, self.port), self.timeout, source_address=self.source_address
        )


def _pinned_https(address: str, context: ssl.SSLContext):
    """Build an HTTPS connection pinned to `address` but speaking to `host`.

    `HTTPSConnection` derives its TLS `server_hostname` from the host it was
    given, which is correct for a name and wrong for an address literal: a
    certificate is issued for `api.example.com`, not for `93.184.216.34`, so
    verifying it against the address would fail every legitimate cloud
    provider. The hostname is therefore kept for the handshake while the socket
    is opened to the pinned address -- the certificate is still verified against
    the name the operator wrote in the manifest, which is the name that decides
    who we are talking to.
    """

    class _Connection(http.client.HTTPSConnection):
        def __init__(self, *args, **kwargs) -> None:
            # The context is bound here rather than left to the stdlib default,
            # so the verifying context the caller built is the one that verifies.
            # Otherwise the hardening below would be a comment next to a context
            # that is built and thrown away.
            super().__init__(*args, context=context, **kwargs)

        def connect(self) -> None:  # noqa: D102 - stdlib interface
            if self._tunnel_host:
                raise TransportError("proxies are not supported for provider egress")
            raw = socket.create_connection(
                (address, self.port), self.timeout, source_address=self.source_address
            )
            try:
                self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
            except BaseException:
                raw.close()
                raise

    return _Connection


def _tls_context() -> ssl.SSLContext:
    """A verifying context, with nothing disabled.

    No REQUESTS_CA_BUNDLE, no check_hostname override, no legacy renegotiation:
    a client that weakens certificate checking to reach one provider has
    weakened it for the key, and the key is the thing being protected.
    """
    context = ssl.create_default_context()
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def _peer_of(sock: socket.socket) -> str | None:
    try:
        return _normalise(sock.getpeername()[0])
    except (OSError, IndexError, TypeError):
        return None


def _read_capped(response: http.client.HTTPResponse, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = response.read(_READ_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise TransportError(
                f"provider response exceeded the {limit} byte limit; refusing to buffer it"
            )
        chunks.append(chunk)
    return b"".join(chunks)


def _auth_headers(provider: egress.Provider, api_key: str) -> dict[str, str]:
    if not provider.requires_key:
        return {}
    if provider.api == "anthropic":
        return {"x-api-key": api_key, "anthropic-version": ANTHROPIC_VERSION}
    return {"Authorization": f"Bearer {api_key}"}


def post(
    decision: egress.Decision,
    path: str,
    payload: dict,
    *,
    api_key: str = "",
    timeout: int = TIMEOUT_S,
    extra_headers: dict[str, str] | None = None,
    max_bytes: int = MAX_RESPONSE_BYTES,
) -> Response:
    """POST `payload` to a cleared provider, on a connection vetted twice.

    `decision` is the gate's, not the caller's: the peer set it was cleared
    against is the peer set this connects to. A caller that wanted a different
    destination would have to forge that, and forging it means not going through
    the gate at all.
    """
    provider = decision.provider
    peers = decision.peers
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    headers = {
        "Host": peers.host,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Content-Length": str(len(body)),
        "User-Agent": USER_AGENT,
        # One request per connection, so every request gets its own peer check.
        "Connection": "close",
    }
    headers.update(_auth_headers(provider, api_key))
    if extra_headers:
        headers.update(extra_headers)

    scheme = provider.base_url.split("://", 1)[0]
    if scheme not in {"http", "https"}:
        raise TransportRefused(f"{provider.id}: unsupported scheme {scheme!r}")

    if scheme == "https":
        context = _tls_context()

    last_error: Exception | None = None
    for address in peers.candidates:
        try:
            if scheme == "https":
                connection = _pinned_https(address, context)(peers.host, port=peers.port, timeout=timeout)
            else:
                connection = _PinnedHTTPConnection(peers.host, address, peers.port, timeout)
            # Connect before sending anything. The peer check has to happen
            # before the prompt is on the wire, not after, or "refused" would
            # be a claim about bytes already sent.
            connection.connect()
        except (OSError, ssl.SSLError) as exc:
            last_error = exc
            continue

        try:
            peer = _peer_of(connection.sock)
            if peer is None or not egress.peer_permitted(peers, peer):
                # The gate cleared a set of addresses and the socket reached
                # something outside it. Nothing has been sent, because the body
                # is written after this check.
                raise TransportRefused(
                    f"{provider.id}: connected to {peer or 'an unknown address'}, which is not "
                    f"a peer this request was cleared for "
                    f"({', '.join(sorted(peers.allowed))}). Refusing: the name resolved to one "
                    "place and the connection reached another."
                )
            connection.request("POST", path, body=body, headers=headers)
            raw = connection.getresponse()
            reply = Response(
                status=raw.status,
                headers={k.lower(): v for k, v in raw.getheaders()},
                body=_read_capped(raw, max_bytes),
            )
        except (OSError, http.client.HTTPException, ssl.SSLError) as exc:
            last_error = exc
            continue
        finally:
            connection.close()

        if 300 <= reply.status < 400:
            target = reply.headers.get("location", "<no location>")
            raise TransportRefused(
                f"{provider.id} answered {reply.status} redirecting to {target}. Refusing to "
                "follow it: the prompt and the API key would go to a host that was never "
                "resolved, checked, or approved."
            )
        return reply

    detail = f"{type(last_error).__name__}: {last_error}" if last_error else "no address answered"
    raise TransportError(
        f"{provider.id}: could not reach any cleared address "
        f"({', '.join(peers.candidates)}): {detail}"
    )


__all__ = [
    "MAX_RESPONSE_BYTES",
    "Response",
    "TransportError",
    "TransportRefused",
    "post",
    "EgressRefused",
]
