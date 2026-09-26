#!/bin/bash
# Regression test for the redirect scope bypass.
#
# Before this test existed, http_headers followed 30x redirects without
# re-checking scope, so any in-scope host could redirect the agent to any
# host on the internet. The response was then written to the engagement's
# audit log as verdict "allowed", making the bypass invisible after the fact.
#
# The test drives two real loopback servers: one in scope (localhost) that
# 302s to a second one (127.0.0.1) that is not in the scope file. The
# assertion that matters is not the text of the refusal but that the
# off-scope server was never contacted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONPATH="$ROOT/mcp-servers/shinobi-recon${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import http.server as httpserver
import sys
import threading

# Aliased: this script has a flat namespace, so importing the stdlib `http`
# and shinobi_recon.httpclient under the same name would shadow one of them.
from shinobi_recon import httpclient as recon

failures = []


def check(condition, message):
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        failures.append(message)


def serve(handler):
    server = httpserver.HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# --- the off-scope host: any request that lands here is the vulnerability ---
off_scope_hits = []


class OffScopeHandler(httpserver.BaseHTTPRequestHandler):
    def do_HEAD(self):
        off_scope_hits.append(self.path)
        self.send_response(200)
        self.send_header("X-Who", "off-scope-secret")
        self.end_headers()

    def log_message(self, *args):
        pass


off_scope = serve(OffScopeHandler)
off_scope_url = f"http://127.0.0.1:{off_scope.server_port}/"

# --- the in-scope host: redirects to the off-scope host ---
redirector_port = {}


class RedirectorHandler(httpserver.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(302)
        self.send_header("Location", off_scope_url)
        self.end_headers()

    def do_GET(self):
        self.do_HEAD()

    def log_message(self, *args):
        pass


redirector = serve(RedirectorHandler)
redirector_url = f"http://localhost:{redirector.server_port}/"

# A scope that covers localhost only. 127.0.0.1 is deliberately absent, which
# is realistic: operators routinely scope a name and not the address it
# resolves to, and this is exactly the case the old code walked straight
# through.
IN_SCOPE = {"localhost", "127.0.0.1"}
SCOPE = {"engagement": "redirect-test", "targets": ["localhost"]}


def authorizer(host):
    if host not in SCOPE["targets"]:
        raise recon.RedirectRefused(f"out-of-scope redirect target {host!r}")


print("== redirect scope bypass ==")

result = recon.fetch_headers(redirector_url, authorize=authorizer)

check(
    off_scope_hits == [],
    f"off-scope host was never contacted (hits={off_scope_hits})",
)
check(result.verdict == "refused", f"verdict is 'refused' (got {result.verdict!r})")
check(
    "off-scope-secret" not in result.output,
    "off-scope response body/headers never reached the caller",
)
check(
    "refused redirect" in result.output,
    f"refusal reason is reported to the caller (got {result.output!r})",
)
check(
    result.detail != "",
    "refusal carries a non-empty detail for the audit log",
)

# --- an in-scope redirect must still work: the guard cannot be a blanket ban ---
# Both hops are addressed as `localhost` because that is the name the scope
# file actually contains. Pointing this at 127.0.0.1 would (correctly) be
# refused, which is the previous test case, not this one.
print("== in-scope redirect still followed ==")

allowed_hits = []


class AllowedHandler(httpserver.BaseHTTPRequestHandler):
    def do_HEAD(self):
        allowed_hits.append(self.path)
        self.send_response(200)
        self.send_header("X-Who", "in-scope")
        self.end_headers()

    def log_message(self, *args):
        pass


allowed = serve(AllowedHandler)
allowed_url = f"http://localhost:{allowed.server_port}/"


class AllowedRedirectorHandler(httpserver.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(301)
        self.send_header("Location", allowed_url)
        self.end_headers()

    def do_GET(self):
        self.do_HEAD()

    def log_message(self, *args):
        pass


allowed_redirector = serve(AllowedRedirectorHandler)

ok_result = recon.fetch_headers(
    f"http://localhost:{allowed_redirector.server_port}/",
    authorize=authorizer,
)
check(ok_result.verdict == "allowed", f"in-scope redirect is allowed (got {ok_result.verdict!r})")
check(allowed_hits != [], "in-scope redirect target was actually contacted")
check("X-Who: in-scope" in ok_result.output, "in-scope headers are returned")

# --- hop limit: an in-scope redirect loop must terminate ---


# --- a redirect chain must terminate ---
print("== redirect chain is bounded ==")

chain_ports = {}


def hop(n):
    class Hop(httpserver.BaseHTTPRequestHandler):
        def do_HEAD(self):
            if n >= len(chain_ports):
                self.send_response(200)
                self.send_header("X-Hops", str(n))
                self.end_headers()
            else:
                self.send_response(302)
                self.send_header("Location", f"http://localhost:{chain_ports[n + 1]}/hop{n + 1}")
                self.end_headers()

        def do_GET(self):
            self.do_HEAD()

        def log_message(self, *args):
            pass

    return serve(Hop)


# Eight distinct in-scope URLs: longer than the default five-hop limit, with
# no URL repeated, so urllib's cycle detection cannot fire and only the
# explicit hop limit can stop this.
servers = [hop(n) for n in range(8)]
for n, srv in enumerate(servers):
    chain_ports[n] = srv.server_port

chain_result = recon.fetch_headers(
    f"http://localhost:{chain_ports[0]}/hop0",
    authorize=authorizer,
)
check(
    chain_result.verdict == "refused" and "redirect limit" in chain_result.output,
    f"over-long redirect chain is refused at the hop limit (got {chain_result.output!r})",
)

# --- a self-referential loop is also refused, by whichever guard trips first ---
print("== self-referential redirect loop is refused ==")


class LoopHandler(httpserver.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(302)
        self.send_header("Location", f"http://localhost:{self.server.server_port}/loop")
        self.end_headers()

    def do_GET(self):
        self.do_HEAD()

    def log_message(self, *args):
        pass


loop = serve(LoopHandler)
loop_result = recon.fetch_headers(f"http://localhost:{loop.server_port}/", authorize=authorizer)
check(
    loop_result.verdict == "refused" and "refused redirect" in loop_result.output,
    f"infinite redirect loop is refused (got {loop_result.output!r})",
)

# --- a url with no host is a caller error, not a network result ---
print("== malformed url ==")
try:
    recon.fetch_headers("http:///nohost", authorize=authorizer)
except ValueError as exc:
    check("no host" in str(exc), f"hostless url raises ValueError (got {exc})")
else:
    check(False, "hostless url raises ValueError")

for server in (off_scope, redirector, allowed, allowed_redirector, loop, *servers):
    server.shutdown()

if failures:
    print(f"\nhttp-headers-test: FAIL ({len(failures)} failed)")
    sys.exit(1)

print("\nhttp-headers-test: PASS")
PY
