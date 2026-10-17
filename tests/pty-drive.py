#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and answer its prompts from a script.

Used by tests of commands that read their answers from the controlling terminal
(/dev/tty) and not from stdin, which a plain pipe cannot exercise: under a pty the
child has a real controlling terminal, so `open("/dev/tty")` works, and this
driver plays the operator at it.

    PTY_SCRIPT='[["Run it now\\?", "y\\n"]]' PTY_OUT=transcript.txt PTY_TIMEOUT=30 \
        pty-drive.py -- command args...

PTY_SCRIPT is a JSON list of [regex, text] pairs, in order: when the regex
matches what the child has printed since the previous step, the text is typed.
PTY_OUT receives everything the child printed to the terminal, with carriage
returns removed.

Exit status: the child's, except 124 when it ran past PTY_TIMEOUT (it is killed)
and 125 when a step's regex never matched (a prompt the test expected did not
appear, which is a failure of the test or of the command and must not read as a
pass). If the child does not need every step, say so by ending the list early.
"""
from __future__ import annotations

import json
import os
import pty
import re
import select
import signal
import sys
import time


def main() -> int:
    script = json.loads(os.environ.pop("PTY_SCRIPT", "[]"))
    out_path = os.environ.pop("PTY_OUT", "")
    timeout = float(os.environ.pop("PTY_TIMEOUT", "30"))
    argv = sys.argv[1:]
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv or not out_path:
        print("usage: PTY_OUT=file [PTY_SCRIPT=json] pty-drive.py -- command...", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(argv[0], argv)
        except OSError as exc:
            print(f"pty-drive: cannot run {argv[0]}: {exc.strerror}", file=sys.stderr)
            os._exit(127)

    transcript = ""
    pending = ""
    step = 0
    deadline = time.monotonic() + timeout
    timed_out = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            os.kill(pid, signal.SIGKILL)
            break
        ready, _, _ = select.select([fd], [], [], min(0.2, remaining))
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                data = b""
            if not data:
                break
            text = data.decode("utf-8", errors="replace").replace("\r", "")
            transcript += text
            pending += text
        # A step may match text that arrived in an earlier read, and several steps
        # may be satisfied by one read, so keep going until none matches.
        while step < len(script) and re.search(script[step][0], pending):
            os.write(fd, script[step][1].encode())
            pending = ""
            step += 1
            # Give the child a moment to consume the answer before the next step
            # is matched against its next output.
            time.sleep(0.05)

    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    code = os.waitstatus_to_exitcode(status)
    with open(out_path, "w", encoding="utf-8") as stream:
        stream.write(transcript)
    if timed_out:
        return 124
    if step < len(script):
        print(f"pty-drive: step {step} never matched: {script[step][0]!r}", file=sys.stderr)
        return 125
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    raise SystemExit(main())
