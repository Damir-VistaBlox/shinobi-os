"""In-scope HTTP header fetching, separate from the MCP tool wrapper.

This lives outside server.py for one concrete reason: server.py imports
FastMCP at module scope, so the request path cannot be imported (and
therefore cannot be tested) without the `mcp` package installed. The scope
gate is the most safety-critical code in this project; the tests for it must
run against plain pyyaml alone.

`fetch_headers` takes an `authorize` callable so the scope decision is
injected rather than imported. That keeps this module free of engagement
state and lets tests drive it with any policy, including a real
`require_in_scope`.
"""
from __future__ import annotations

import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Callable

TIMEOUT_S = 30
USER_AGENT = "ShinobiOS/1"

# Callables that raise to refuse a host. Kept deliberately loose: the real one
# is scope.ScopeError, and tests use their own.
Authorizer = Callable[[str], None]


class RedirectRefused(RuntimeError):
    """A redirect was rejected by the authorizer or the hop limit."""


@dataclass(frozen=True)
class HeaderResult:
    """Result of a header fetch.

    `verdict` is the audit verdict for the whole call, including any redirect
    hops: a call that was redirected onto an unauthorized host is "refused",
    never "allowed" no matter how many hops succeeded first.
    """

    output: str
    verdict: str
    detail: str = ""


def validate_port(port: int | None) -> None:
    if port is not None and not (1 <= port <= 65535):
        raise ValueError("port must be between 1 and 65535")


def build_url(scheme: str, host: str, port: int | None) -> str:
    authority = f"{host}:{port}" if port is not None else host
    return f"{scheme}://{authority}/"


def _format(reply) -> str:
    lines = [f"HTTP {reply.status} {reply.reason}"]
    lines.extend(f"{key}: {value}" for key, value in reply.headers.items())
    return "\n".join(lines)


class _ScopedRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Re-authorize every redirect hop instead of trusting the first URL.

    urllib follows 301/302/303/307/308 transparently, so an in-scope host
    can bounce the request onto any host on the internet. Only the first URL
    is ever scope-checked, which made the whole gate bypassable by any host
    the engagement does touch. Every hop is therefore re-validated against
    the same policy before the request is allowed to proceed.
    """

    def __init__(self, authorize: Authorizer | None, max_redirects: int) -> None:
        self._authorize = authorize
        self._remaining = max_redirects

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001, ANN201
        if self._remaining <= 0:
            raise RedirectRefused(f"redirect limit exceeded at {newurl}")
        host = urllib.parse.urlsplit(newurl).hostname
        if not host:
            raise RedirectRefused(f"redirect target has no host: {newurl}")
        if self._authorize is not None:
            self._authorize(host)
        self._remaining -= 1
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_headers(
    url: str,
    *,
    authorize: Authorizer | None = None,
    timeout: int = TIMEOUT_S,
    max_redirects: int = 5,
) -> HeaderResult:
    """HEAD `url` and return its status line and headers.

    `authorize` is called with the hostname of the initial request and of
    every redirect hop. To refuse a host it must raise RedirectRefused --
    that is the whole authorizer contract, and it keeps this module free of
    engagement state so tests can drive it with any policy.
    """
    host = urllib.parse.urlsplit(url).hostname
    if not host:
        raise ValueError(f"url has no host: {url}")

    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    opener = urllib.request.build_opener(_ScopedRedirectHandler(authorize, max_redirects))
    try:
        if authorize is not None:
            authorize(host)
        with opener.open(request, timeout=timeout) as reply:
            return HeaderResult(_format(reply), "allowed")
    except RedirectRefused as exc:
        return HeaderResult(f"http_headers: refused redirect: {exc}", "refused", str(exc))
    except urllib.error.HTTPError as exc:
        # A 3xx here means the redirect could not be followed: either our own
        # hop limit tripped or urllib detected a cycle. Nothing was fetched
        # from the intended target, so this is a refusal, not an authorized
        # call. Treating it as "allowed" is how an unbounded redirect chain
        # ends up recorded in the audit log as a success.
        if 300 <= exc.code < 400:
            detail = f"redirect to {exc.headers.get('Location', '<unknown>')} not followed"
            return HeaderResult(f"http_headers: refused redirect: {detail}", "refused", detail)
        # Any other status is a genuine response from an authorized host:
        # a 404 or 500 means the request was allowed and the server refused.
        return HeaderResult(_format(exc), "allowed")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return HeaderResult(f"http_headers: request failed: {exc}", "allowed", str(exc))
