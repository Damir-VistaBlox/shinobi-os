"""`shinobi agent install | login | setup | registry`: guide-only vendor agent setup.

Installing Claude Code or Codex means running the vendor's installer, and logging
in means starting the vendor's own CLI. Neither is something Shinobi should do
quietly on someone's behalf, and neither is something it can make safe. So this
command shows the operator exactly what will run, waits for them to say yes at
their own terminal, runs it there where they can watch it, and writes down that
it did. It does not download anything itself, does not read what the vendor
leaves behind, and does not touch the operator's shell profile.

The rules, each of which a test pins:

  * What runs comes from the fixed table in agentreg, selected by an id. Nothing
    an operator, a config file or an environment variable says can change it.
  * The confirmation is read from the controlling terminal, never from stdin, so
    `yes | shinobi agent install claude` confirms nothing. With no terminal the
    command refuses. There is no --yes, and no environment override.
  * The ungoverned-egress acknowledgement is separate from that confirmation. The
    agent's own model traffic is outside the egress gate; saying so is the same
    acknowledgement `shinobi agent` asks for, may come from the same flag or
    variable, and is recorded the same way. It never stands in for the
    confirmation.
  * Intent is recorded *before* vendor code runs, and if it cannot be recorded
    nothing runs. (providerctl reports an unrecorded change afterwards because
    there the change has already happened; here nothing has.)
  * The vendor's output goes to the terminal and nowhere else. A login can print
    a device code or a URL, so none of it is captured, logged or published.
  * Claude Code's login is a full agent session. It is started in an empty
    temporary directory, so it cannot pick up a project's own agent settings or
    server list, and the operator is told to do real work through `shinobi agent`.
  * Whether a login worked is asked of the vendor's CLI where it has a command for
    it. Shinobi never reads a vendor's credential store.
"""
from __future__ import annotations

import json
import os
import pwd
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import IO

from . import agentreg
from .agentreg import AgentError, VendorAgent

_ACK_ENV = "SHINOBI_ACCEPT_UNGOVERNED_EGRESS"
_STATUS_TIMEOUT = 30

USAGE = """\
Usage: shinobi agent <install|login|setup|registry> ...

  registry [--json]                   the vendor agents Shinobi can set up, and
                                      which are installed
  install <id> [--accept-ungoverned-egress]
                                      show the vendor's install command and run it
                                      if you confirm, at your terminal
  login <id> [--accept-ungoverned-egress]
                                      hand off to the vendor's own login
  setup <id> [--accept-ungoverned-egress]
                                      install if missing, log in, then offer to
                                      make it your default agent

An agent's model traffic is NOT governed by Shinobi's egress gate (that is true of
'shinobi agent' too), so these commands ask you to acknowledge it: with the flag,
with SHINOBI_ACCEPT_UNGOVERNED_EGRESS=1, or at the prompt. Installing always needs
a terminal and your confirmation there; there is no way around either.
"""


def _say(text: str = "") -> None:
    print(text, flush=True)


def _err(text: str) -> None:
    print(f"shinobi-agent: {text}", file=sys.stderr, flush=True)


def _actor() -> str:
    try:
        return pwd.getpwuid(os.geteuid()).pw_name[:64] or "unknown"
    except KeyError:
        return "unknown"


class _Tty:
    """The operator's terminal: one stream to read answers from, one to write to.

    Two streams, because a text stream opened for both reading and writing wants
    to seek, and a terminal cannot.
    """

    def __init__(self, reader: IO[str], writer: IO[str]) -> None:
        self.reader = reader
        self.writer = writer

    def write(self, text: str) -> None:
        self.writer.write(text)

    def flush(self) -> None:
        self.writer.flush()

    def readline(self) -> str:
        return self.reader.readline()

    def close(self) -> None:
        for stream in (self.reader, self.writer):
            try:
                stream.close()
            except OSError:
                pass


def _open_tty() -> _Tty | None:
    """The controlling terminal, or None when there is not one.

    Opened by name, so it is the operator's terminal even when stdin, stdout and
    stderr have all been redirected somewhere else.
    """
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        reader = os.fdopen(os.dup(fd), "r", encoding="utf-8", errors="replace")
        writer = os.fdopen(fd, "w", buffering=1, encoding="utf-8", errors="replace")
    except OSError:
        return None
    return _Tty(reader, writer)


def _ask(tty: _Tty, question: str, default_yes: bool = False) -> bool:
    """A yes/no question at the terminal. Anything but a clear yes is a no
    (unless the default is yes and the answer is empty), and so is end of file."""
    tty.write(question + (" [Y/n] " if default_yes else " [y/N] "))
    tty.flush()
    answer = tty.readline()
    if answer == "":
        tty.write("\n")
        return False
    answer = answer.strip().lower()
    if answer == "":
        return default_yes
    return answer in ("y", "yes")


class _Session:
    """What one command invocation knows: the terminal, and whether the
    ungoverned-egress acknowledgement has been given (once per invocation, even
    when `setup` goes through two steps)."""

    def __init__(self, flag: bool) -> None:
        self.flag = flag
        self.tty: _Tty | None = _open_tty()
        self.ack: str | None = None

    def close(self) -> None:
        if self.tty is not None:
            self.tty.close()

    def acknowledge(self, agent: VendorAgent) -> bool:
        if self.ack is not None:
            return True
        if self.tty is not None:
            self.tty.write(
                f"\n{agent.name} talks to its model provider directly. Shinobi's egress gate governs\n"
                "'shinobi llm' and cannot see a process that opens its own connection, so this\n"
                "agent's model traffic is NOT governed by it, and neither is its login or the\n"
                "installer. What stays governed is the agent's tools, once you start it with\n"
                "'shinobi agent': the scope gate, the approvals and the audit record.\n"
            )
        if self.flag:
            self.ack = "flag"
        elif os.environ.get(_ACK_ENV) == "1":
            self.ack = "env"
        elif self.tty is not None and _ask(self.tty, "Do you accept that, and continue?"):
            self.ack = "prompt"
        else:
            _err(
                "not continuing without the acknowledgement that the agent's model traffic is outside the egress gate.\n"
                "  Pass --accept-ungoverned-egress, set SHINOBI_ACCEPT_UNGOVERNED_EGRESS=1, or answer yes at the prompt."
            )
            return False
        return True


def _need_tty(session: _Session, what: str) -> bool:
    if session.tty is not None:
        return True
    _err(
        f"{what} needs a terminal. It shows you what will run and waits for your answer there,\n"
        "  and nothing is run without that. Run it from a terminal window."
    )
    return False


def _record(capability: str, arguments: dict, status: str, detail: str) -> Exception | None:
    """Write one audit record. Returns the failure, or None."""
    from . import audit

    try:
        audit.write(actor=_actor(), capability=capability, arguments=arguments, status=status, detail=detail)
    except Exception as exc:  # noqa: BLE001 - any failure to record is a failure to record
        return exc
    return None


def _publish(event: str, payload: dict) -> None:
    from . import events

    try:
        events.publish(event, payload)
    except (OSError, ValueError):
        pass  # the audit record is the record; the event bus is a convenience


def _run(argv: list[str], session: _Session, cwd: str, timeout: float | None = None) -> int:
    """Run a command with the terminal as stdin, stdout and stderr, and return its
    exit status (130 if interrupted). Nothing it prints is captured."""
    assert session.tty is not None
    try:
        completed = subprocess.run(
            argv,
            stdin=session.tty.reader,
            stdout=session.tty.writer,
            stderr=session.tty.writer,
            cwd=cwd,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return 124
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        _err(f"could not run it: {exc.strerror or type(exc).__name__}")
        return 127
    return completed.returncode


def _describe(found: agentreg.Found | None) -> str:
    if found is None:
        return "not found"
    return f"found on PATH ({found.path})" if found.on_path else f"found off PATH ({found.path})"


def _off_path_hint(agent: VendorAgent, found: agentreg.Found) -> None:
    folder = str(Path(found.path).parent)
    _say(
        f"  {agent.binary} is at {found.path}, which is not on your PATH, so 'shinobi agent' will not\n"
        f"  find it by name. Add {folder} to PATH in your shell profile (Shinobi does not edit it),\n"
        "  then open a new terminal."
    )


def cmd_install(agent_id: str, session: _Session) -> int:
    agent = agentreg.get(agent_id)
    found = agentreg.find_binary(agent)
    if found is not None:
        _say(f"{agent.name} is already installed: {found.path}")
        if not found.on_path:
            _off_path_hint(agent, found)
        return 0
    if not _need_tty(session, "'shinobi agent install'"):
        return 1
    missing = agentreg.missing_tools(agent)
    if missing:
        _err(f"the {agent.name} installer needs {', '.join(missing)} on PATH, and it is not there.")
        return 1
    if not session.acknowledge(agent):
        return 1

    tty = session.tty
    assert tty is not None
    tty.write(
        f"\nInstall {agent.name}\n"
        "\n"
        "  Shinobi will run exactly this, as you (not as root), here, where you can watch it:\n"
        "\n"
        f"      {agent.install_text}\n"
        "\n"
        f"  It downloads from {', '.join(agent.install_hosts)} and runs what it downloads. Shinobi has not read\n"
        "  that script and cannot vouch for it. The vendor documents this command at\n"
        f"  {agent.docs[0]} (read on {agent.verified}).\n"
        "\n"
    )
    if not _ask(tty, "Run it now?"):
        _say("Nothing was run.")
        return 1

    failure = _record("agent.install", {"agent": agent.id, "ack": session.ack}, "started", "install confirmed at the terminal")
    if failure is not None:
        _err(
            f"nothing was run: the audit journal could not be written ({getattr(failure, 'strerror', None) or type(failure).__name__}),\n"
            "  and a vendor installer is not run without a record that it was."
        )
        return 1

    with tempfile.TemporaryDirectory(prefix="shinobi-agent-install-") as workdir:
        # bash, always, with pipefail: a failed download would otherwise hand the
        # shell an empty script, which it runs successfully. The text is the
        # vendor's pipeline, unchanged; only the shell around it is ours.
        rc = _run(["bash", "-o", "pipefail", "-c", agent.install_text], session, workdir)

    found = agentreg.find_binary(agent)
    ok = rc == 0 and found is not None
    recorded = _record(
        "agent.install",
        {"agent": agent.id, "ack": session.ack},
        "completed" if ok else "failed",
        f"installer exit status {rc}; binary {_describe(found)}",
    )
    _publish("agent.install.finished", {"agent": agent.id, "ok": ok, "exit_code": rc, "found": found is not None})
    if recorded is not None:
        _err("the install was attempted, but it could NOT be recorded in the audit journal. Treat it as unaudited.")
    if not ok:
        if rc != 0:
            _err(f"the installer exited with status {rc}; {agent.name} is not installed. What it printed is above.")
        else:
            _err(f"the installer finished, but {agent.binary} is not on PATH or in {', '.join('~/' + d for d in agent.search_dirs)}.")
        return 1
    _say(f"\n{agent.name} is installed: {found.path}")
    if not found.on_path:
        _off_path_hint(agent, found)
    return 0 if recorded is None else 1


def cmd_login(agent_id: str, session: _Session) -> int:
    agent = agentreg.get(agent_id)
    found = agentreg.find_binary(agent)
    if found is None:
        _err(f"{agent.name} is not installed. Run 'shinobi agent install {agent.id}' first.")
        return 1
    if not _need_tty(session, "'shinobi agent login'"):
        return 1
    if not session.acknowledge(agent):
        return 1

    tty = session.tty
    assert tty is not None
    argv = [found.path, *agent.login_args]
    tty.write(
        f"\nLog in to {agent.name}\n"
        "\n"
        f"  This starts {' '.join(argv)} in an empty temporary directory, and hands the terminal to it.\n"
        "  The login is the vendor's: Shinobi does not see it, store it, or read the files it leaves.\n"
        "\n"
        + "\n".join("  " + line for line in agent.login_note.splitlines())
        + "\n\n"
    )

    failure = _record("agent.login", {"agent": agent.id, "ack": session.ack}, "started", "login handed to the vendor CLI")
    if failure is not None:
        _err(
            f"nothing was run: the audit journal could not be written ({getattr(failure, 'strerror', None) or type(failure).__name__}),\n"
            "  and a login is not handed off without a record that it was."
        )
        return 1

    with tempfile.TemporaryDirectory(prefix="shinobi-agent-login-") as workdir:
        rc = _run(argv, session, workdir)
        verdict = "not known"
        if agent.status_args is not None:
            tty.write(f"\nAsking {agent.binary} whether you are logged in:\n")
            status_rc = _run([found.path, *agent.status_args], session, workdir, timeout=_STATUS_TIMEOUT)
            verdict = "logged in" if status_rc == 0 else f"not logged in (status exit {status_rc})"

    recorded = _record(
        "agent.login",
        {"agent": agent.id, "ack": session.ack},
        "completed" if rc == 0 else "failed",
        f"vendor CLI exit status {rc}; login state: {verdict}",
    )
    _publish("agent.login.finished", {"agent": agent.id, "ok": rc == 0, "exit_code": rc, "login": verdict})
    if recorded is not None:
        _err("the login was handed off, but that could NOT be recorded in the audit journal. Treat it as unaudited.")
    if rc != 0:
        _err(f"{agent.binary} exited with status {rc}.")
        return 1
    if agent.status_args is None:
        _say(
            f"\n{agent.name} has no command Shinobi can ask whether you are logged in, and Shinobi does not\n"
            "look in its credential files. If you saw 'Login successful', you are."
        )
    else:
        _say(f"\n{agent.name}: {verdict}.")
    return 0 if recorded is None else 1


def _default_agent_script() -> str | None:
    bin_dir = os.environ.get("SHINOBI_BIN_DIR")
    if bin_dir:
        candidate = Path(bin_dir) / "shinobi-default-agent"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("shinobi-default-agent")


def cmd_setup(agent_id: str, session: _Session) -> int:
    agent = agentreg.get(agent_id)
    rc = cmd_install(agent_id, session)
    if rc != 0:
        return rc
    rc = cmd_login(agent_id, session)
    if rc != 0:
        return rc
    tty = session.tty
    assert tty is not None
    tty.write("\n")
    if _ask(tty, f"Make {agent.name} your default agent for 'shinobi agent'?", default_yes=True):
        script = _default_agent_script()
        if script is None:
            _err("could not find shinobi-default-agent. Run 'shinobi default agent " + agent.id + "' yourself.")
            return 1
        with tempfile.TemporaryDirectory(prefix="shinobi-agent-default-") as workdir:
            if _run([script, agent.id], session, workdir) != 0:
                _err(f"it was not made the default. Once '{agent.binary}' is on PATH: shinobi default agent {agent.id}")
                return 1
    _say(f"\nStart it, governed where it can be, with: shinobi agent --accept-ungoverned-egress")
    return 0


def _read_default_agent() -> str | None:
    path = Path(os.environ.get("HOME") or Path.home()) / ".config/shinobi/default-agent"
    try:
        with path.open(encoding="utf-8") as stream:
            first = stream.readline().strip()
    except OSError:
        return None
    return first or None


def cmd_registry(as_json: bool) -> int:
    from .llm.mcp import supports_mcp_registration

    default = _read_default_agent()
    rows = []
    for agent in agentreg.AGENTS:
        found = agentreg.find_binary(agent)
        rows.append(
            {
                "id": agent.id,
                "name": agent.name,
                "binary": agent.binary,
                "installed": found is not None,
                "path": found.path if found else None,
                "on_path": found.on_path if found else None,
                "default": default == agent.binary,
                "mcp": supports_mcp_registration(agent.binary),
                "egress": agentreg.EGRESS,
                "install_command": agent.install_text,
                "login_command": " ".join([agent.binary, *agent.login_args]),
                "login_state": "ask the vendor CLI" if agent.status_args else "not known",
            }
        )
    if as_json:
        print(json.dumps({"agents": rows}, indent=2, sort_keys=True))
        return 0
    for row in rows:
        state = "installed" if row["installed"] else "not installed"
        if row["installed"] and not row["on_path"]:
            state += ", off PATH"
        extras = "  (default)" if row["default"] else ""
        _say(f"{row['id']:8} {row['name']:18} {state}{extras}")
        _say(f"         egress: {row['egress']}   mcp tools: {'yes' if row['mcp'] else 'no'}")
        _say(f"         install: {row['install_command']}")
    return 0


def _parse(argv: list[str], flags: tuple[str, ...], positional: int) -> tuple[list[str], set[str]] | None:
    """The positional arguments and the flags given, or None for a usage error.
    Nothing here repeats an argument back: it may be a prompt pasted in by mistake."""
    words: list[str] = []
    given: set[str] = set()
    for arg in argv:
        if arg.startswith("-"):
            if arg not in flags:
                return None
            given.add(arg)
        else:
            words.append(arg)
    if len(words) != positional:
        return None
    return words, given


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    action = args[0] if args else ""
    rest = args[1:]

    if action in ("", "-h", "--help", "help"):
        print(USAGE, end="")
        return 0 if action else 2

    if action == "registry":
        parsed = _parse(rest, ("--json",), 0)
        if parsed is None:
            print("usage: shinobi agent registry [--json]", file=sys.stderr)
            return 2
        return cmd_registry("--json" in parsed[1])

    handlers = {"install": cmd_install, "login": cmd_login, "setup": cmd_setup}
    if action not in handlers:
        print("shinobi-agent: unknown action. See 'shinobi agent help'.", file=sys.stderr)
        return 2
    parsed = _parse(rest, ("--accept-ungoverned-egress",), 1)
    if parsed is None:
        print(f"usage: shinobi agent {action} <id> [--accept-ungoverned-egress]", file=sys.stderr)
        return 2
    words, given = parsed
    session = _Session("--accept-ungoverned-egress" in given)
    try:
        return handlers[action](words[0], session)
    except AgentError as exc:
        _err(str(exc))
        return 1
    finally:
        session.close()


if __name__ == "__main__":
    raise SystemExit(main())
