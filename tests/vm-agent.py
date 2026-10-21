#!/usr/bin/env python3
"""The host side of a command channel into a QEMU guest that has no other way in.

    vm-agent.py DIR [--port N]

Serves DIR to the guest and takes its uploads, on 127.0.0.1 (QEMU's user-mode network
reaches the host's loopback as 10.0.2.2). The first line it prints is `PORT <n>`.

The guest runs tests/fixtures/guest-agent.sh, which polls `<session>/cmd.1.sh`,
`cmd.2.sh`, ... under this server, runs each, and uploads what it printed as
`<session>/out.N`. The host side is "write cmd.N.sh into DIR/<session>, wait for out.N".
A session is a directory name, one per boot, because an agent counts from 1 and would
otherwise run the last boot's commands again.

It is deliberately narrow, because the guest is the thing under test: files are served
only from DIR (no path leaves it), and an upload is accepted only as
`/<session>/out.<number>` and at most 4 MiB, into DIR itself.
"""
import argparse
import functools
import http.server
import os
import re
import sys

MAX_UPLOAD = 4 * 1024 * 1024
UPLOAD_PATH = re.compile(r"^/([a-z0-9]{1,16})/(out\.[0-9]{1,6})$")


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_PUT(self):
        match = UPLOAD_PATH.match(self.path)
        length = int(self.headers.get("Content-Length", "0") or 0)
        if not match or length < 0 or length > MAX_UPLOAD:
            self.send_error(400)
            return
        directory = os.path.join(self.directory, match.group(1))
        if not os.path.isdir(directory):
            self.send_error(404)
            return
        with open(os.path.join(directory, match.group(2)), "wb") as handle:
            handle.write(self.rfile.read(length))
        self.send_response(201)
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    handler = functools.partial(Handler, directory=os.path.abspath(args.directory))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print(f"PORT {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
