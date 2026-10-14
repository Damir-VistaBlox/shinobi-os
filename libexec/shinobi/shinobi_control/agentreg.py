"""The vendor agent CLIs Shinobi can help install and log in to.

This is a table of commands the operator will be asked to run, so it is small,
fixed, and checked: two entries, both copied from the vendor's own documentation
(each carries the page and the date it was read), and nothing that reads a file
or an environment variable to extend it. A registry an operator or a package
could extend would be a way to get an arbitrary command in front of a prompt that
says "the vendor's install command"; a registry that cannot be extended is not.

It is deliberately not `providers/*.toml`. Those manifests describe API endpoints
that Shinobi's egress gate governs: a request goes out only with a stored key,
an engagement's clearance and a per-turn approval. A vendor agent is the other
thing. It dials its own provider from inside its own process, where the gate
cannot see it, and it keeps its own login in its own credential store. Listing
`claude` beside `openai` would imply the gate governs both, which is the claim
this project has spent effort removing. So every entry here says, in a constant
nobody can override, that its egress is ungoverned.

Shinobi never reads a vendor's credential store. Whether a login worked is a
question for the vendor's CLI, and where that CLI has no command for it, the
answer is "not known" rather than a look inside the vendor's own files.
"""
from __future__ import annotations

import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

# Every entry's egress. A module constant, not a field, so that no entry can say
# otherwise.
EGRESS = "ungoverned"

AGENT_ID_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")


class AgentError(RuntimeError):
    """A request that names no agent we manage. Never carries the argument."""


@dataclass(frozen=True)
class VendorAgent:
    id: str
    name: str
    binary: str
    # The vendor's install command, verbatim from its documentation. It is a
    # shell pipeline (`curl ... | bash`), run as the text it is shown as and never
    # assembled from anything else.
    install_text: str
    # The host the install script itself is fetched from. What that script goes on
    # to download is its own business and is not listed: a list that looked
    # complete and was not would be worse than saying so.
    install_hosts: tuple[str, ...]
    # Programs the install text needs on PATH, including the shell it pipes into.
    install_needs: tuple[str, ...]
    # Arguments after the binary that start the vendor's own login.
    login_args: tuple[str, ...]
    # What the operator needs to know before the login starts, shown first.
    login_note: str
    # Arguments after the binary that report the login state, where the vendor has
    # such a command. None means "the vendor offers no way to ask", and Shinobi
    # does not go and look at the credential files to find out.
    status_args: tuple[str, ...] | None
    # Directories (under the home directory) where the vendor's installer puts the
    # binary, searched after PATH, because a fresh install is often not on PATH yet.
    search_dirs: tuple[str, ...]
    docs: tuple[str, ...]
    verified: str  # the date the commands above were read from `docs`


AGENTS: tuple[VendorAgent, ...] = (
    VendorAgent(
        id="claude",
        name="Claude Code",
        binary="claude",
        install_text="curl -fsSL https://claude.ai/install.sh | bash",
        install_hosts=("claude.ai",),
        install_needs=("curl", "bash"),
        login_args=(),
        login_note=(
            "Claude Code has no separate login command: it asks you to log in the first\n"
            "time it starts, and what starts is a full Claude Code session, with its own\n"
            "shell tool, and without Shinobi's engagement, scope gate or run record.\n"
            "It is started here in an empty temporary directory, only so that you can log in.\n"
            "  1. Finish the login in the browser window it opens.\n"
            "  2. When it says 'Login successful', type /exit.\n"
            "  3. Do real work through 'shinobi agent', not in this session."
        ),
        status_args=None,
        search_dirs=(".local/bin",),
        docs=("https://code.claude.com/docs/en/setup", "https://code.claude.com/docs/en/authentication"),
        verified="2026-10-14",
    ),
    VendorAgent(
        id="codex",
        name="OpenAI Codex CLI",
        binary="codex",
        install_text="curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        install_hosts=("chatgpt.com",),
        install_needs=("curl", "sh"),
        login_args=("login",),
        login_note=(
            "'codex login' opens a browser to sign in with ChatGPT. On a machine with no\n"
            "browser, cancel it and run 'codex login --device-auth' yourself."
        ),
        status_args=("login", "status"),
        search_dirs=(".local/bin",),
        docs=("https://github.com/openai/codex", "https://learn.chatgpt.com/docs/auth"),
        verified="2026-10-14",
    ),
)


def _validate() -> None:
    seen: set[str] = set()
    for agent in AGENTS:
        if not AGENT_ID_RE.fullmatch(agent.id) or agent.id in seen:
            raise AgentError("the agent registry is malformed")
        seen.add(agent.id)
        # The binary is a bare name: it is looked up, never joined onto a path
        # that came from somewhere else.
        if "/" in agent.binary or not AGENT_ID_RE.fullmatch(agent.binary):
            raise AgentError("the agent registry is malformed")


_validate()


def ids() -> list[str]:
    return [agent.id for agent in AGENTS]


def get(agent_id: object) -> VendorAgent:
    """The entry for an id, or an error that does not repeat what was asked for.

    The argument may be anything a shell put there, including a prompt pasted
    into the wrong place, so it is never quoted back.
    """
    if isinstance(agent_id, str) and AGENT_ID_RE.fullmatch(agent_id):
        for agent in AGENTS:
            if agent.id == agent_id:
                return agent
    raise AgentError(
        "that is not a vendor agent this system manages (known: " + ", ".join(ids()) + ")"
    )


@dataclass(frozen=True)
class Found:
    path: str
    on_path: bool


def find_binary(agent: VendorAgent, home: Path | None = None) -> Found | None:
    """Where the agent's binary is, looking on PATH first and then where its
    installer is documented to put it.

    A binary found only off PATH is reported as such: `shinobi agent` launches
    by name, so it will not find it until the operator fixes their PATH, and
    saying "installed" without saying that would send them to a confusing error
    later. Nothing here edits a shell profile.
    """
    on_path = shutil.which(agent.binary)
    if on_path:
        return Found(on_path, True)
    base = home if home is not None else Path(os.environ.get("HOME") or Path.home())
    for rel in agent.search_dirs:
        candidate = base / rel / agent.binary
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return Found(str(candidate), False)
    return None


def missing_tools(agent: VendorAgent) -> list[str]:
    return [tool for tool in agent.install_needs if shutil.which(tool) is None]
