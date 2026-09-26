"""API key storage for LLM providers.

An API key is the one secret in this project that is worth stealing twice: it
bills someone, and for a cloud model it is the credential that carries client
data off the machine. So the rules here are narrow on purpose.

Keys are never written to a manifest. `providers/*.toml` describes *where* a
provider is and *what* it is; a key is stored separately and reached by id, so
reading a provider's policy never reveals anything about its credentials and
committing the manifests can never leak one.

Keys are never passed in argv. `subprocess` arguments are world-readable in
/proc/<pid>/cmdline for the lifetime of the call, which on a shared box is the
whole session, and this project already hands argument dicts to a helper
process for approvals. Every key operation therefore goes through stdin or
stdout.

Keys are never logged. Nothing in this module prints one, and no key is ever
part of an error message, because these errors reach the audit log.

Where the key lives depends on the machine, and the choice is made here rather
than offered to the operator:

  * Live image -> the Linux kernel keyring. The live image is written to
    removable media, so a plaintext key on that medium is a key that exists on
    whatever the stick is later plugged into. The keyring is kernel memory: it
    never reaches a filesystem, and it is session-scoped, so a reboot discards
    it. That is the correct trade for a medium that leaves the building.
  * Installed system -> a 0600 file under the state directory, so a key
    survives the reboots a multi-day engagement has.

The backend is not configurable. An operator who could pick would eventually
pick the wrong one on a stick, and the whole reason for the split is that the
live case is the dangerous one.

`keyctl` comes from the `keyutils` package. On a live image without it, key
storage refuses rather than quietly falling back to a file: falling back would
write the key to the removable medium, which is exactly the outcome this
module exists to prevent.
"""
from __future__ import annotations

import os
import re
import stat
import subprocess
from pathlib import Path

from .policy import is_live_mode

# Provider ids come from manifests and from argv, and they name a file in the
# file backend, so the grammar is closed: no separators, no dot-only runs, and
# a length bound. `..` cannot be expressed. This is the same rule the other
# name-taking paths in the project use.
PROVIDER_ID_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")

KEYRING_PREFIX = "shinobi-provider-"


class CredentialError(RuntimeError):
    """Raised when a key cannot be stored, read, or removed.

    Deliberately never constructed with the key in the message: these strings
    reach the engagement log.
    """


def _check_id(provider_id: str) -> str:
    if not isinstance(provider_id, str) or not PROVIDER_ID_RE.fullmatch(provider_id):
        raise CredentialError(f"invalid provider id: {provider_id!r}")
    if ".." in provider_id:
        raise CredentialError(f"invalid provider id: {provider_id!r}")
    return provider_id


def backend() -> str:
    """Which store this machine uses: 'keyring' or 'file'."""
    return "keyring" if is_live_mode() else "file"


def key_dir() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/providers"


def _key_path(provider_id: str) -> Path:
    return key_dir() / f"{_check_id(provider_id)}.key"


def _keyring_available() -> bool:
    try:
        subprocess.run(
            ["keyctl", "--version"],
            capture_output=True,
            timeout=10,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def _keyring(desc: str, *args: str, stdin: str | None = None) -> str:
    """Run keyctl, keeping the secret off argv and returning stdout.

    `padd`/`request`/`unlink` are used rather than `add` precisely because
    `add` takes its payload as an argument.
    """
    try:
        result = subprocess.run(
            ["keyctl", args[0], "user", desc, *args[1:]],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CredentialError(f"keyctl failed: {type(exc).__name__}") from exc
    if result.returncode != 0:
        # stderr can echo the payload for some subcommands, so it is not
        # included; the exit code is enough to act on and leaks nothing.
        raise CredentialError(f"keyctl {args[0]} failed with status {result.returncode}")
    return result.stdout


def set_key(provider_id: str, secret: str) -> str:
    """Store `secret` for a provider. Returns the backend used, never the key."""
    _check_id(provider_id)
    if not isinstance(secret, str) or not secret.strip():
        raise CredentialError("refusing to store an empty provider key")
    if "\x00" in secret or "\n" in secret:
        # A newline would split a keyctl stdin payload across keys, and a NUL
        # cannot survive the round trip at all.
        raise CredentialError("refusing to store a key containing NUL or newline")

    if backend() == "keyring":
        if not _keyring_available():
            raise CredentialError(
                "the live image has no keyctl (install keyutils), and falling back "
                "to a file would write the key to removable media. Refusing."
            )
        _keyring(KEYRING_PREFIX + provider_id, "padd", stdin=secret)
        return "keyring"

    path = _key_path(provider_id)
    root = path.parent
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        info = os.stat(root, follow_symlinks=False)
    except OSError as exc:
        raise CredentialError(f"cannot use the credential directory: {exc.strerror}") from exc
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
        # A directory anyone else can write holds keys anyone else can replace.
        raise CredentialError(
            f"refusing credential directory {root}: mode {stat.filemode(info.st_mode)} "
            "is group- or world-accessible. Run 'chmod 0700' on it to fix."
        )

    # O_EXCL against a private temp file, then rename, so a reader never sees a
    # half-written key and never sees one at a predictable name. Same protocol
    # approval.py uses for its records.
    tmp = path.with_suffix(".key.tmp")
    try:
        handle = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise CredentialError(
            f"a stale temporary credential file exists at {tmp}; remove it and retry"
        ) from exc
    except OSError as exc:
        raise CredentialError(f"cannot write the credential file: {exc.strerror}") from exc
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(secret)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise CredentialError(f"cannot write the credential file: {exc.strerror}") from exc
    os.chmod(path, 0o600)
    return "file"


def get_key(provider_id: str) -> str:
    """Read the stored key for a provider.

    The one function whose return value is a secret, so it is deliberately not
    a general accessor: callers that only need to know *whether* a key exists
    should use has_key, and callers that render provider state should never
    route through here.
    """
    if backend() == "keyring":
        if not _keyring_available():
            raise CredentialError("the live image has no keyctl, so stored keys are unreachable")
        secret = _keyring(KEYRING_PREFIX + provider_id, "request").strip()
        if not secret:
            raise CredentialError(f"no key stored for provider {provider_id!r}")
        return secret

    path = _key_path(provider_id)
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise CredentialError(f"no key stored for provider {provider_id!r}") from None
    except OSError as exc:
        raise CredentialError(f"cannot read the credential file: {exc.strerror}") from exc
    if not stat.S_ISREG(info.st_mode):
        # A symlink here would let a readable path redirect the read.
        raise CredentialError(f"refusing credential file {path}: not a regular file")
    if info.st_mode & 0o077:
        raise CredentialError(
            f"refusing credential file {path}: mode {stat.filemode(info.st_mode)} is "
            "group- or world-accessible. Run 'chmod 0600' on it to fix."
        )
    try:
        secret = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise CredentialError(f"cannot read the credential file: {type(exc).__name__}") from exc
    if not secret:
        raise CredentialError(f"the stored key for provider {provider_id!r} is empty")
    return secret


def has_key(provider_id: str) -> bool:
    """Whether a key is stored, without reading it into the process."""
    _check_id(provider_id)
    if backend() == "keyring":
        if not _keyring_available():
            return False
        try:
            _keyring(KEYRING_PREFIX + provider_id, "request")
        except CredentialError:
            return False
        return True
    path = _key_path(provider_id)
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and not info.st_mode & 0o077


def forget_key(provider_id: str) -> bool:
    """Remove a stored key. Returns whether there was one to remove."""
    _check_id(provider_id)
    if backend() == "keyring":
        if not _keyring_available():
            raise CredentialError("the live image has no keyctl, so stored keys cannot be removed")
        try:
            _keyring(KEYRING_PREFIX + provider_id, "unlink")
        except CredentialError:
            return False
        return True
    path = _key_path(provider_id)
    try:
        path.unlink()
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise CredentialError(f"cannot remove the credential file: {exc.strerror}") from exc
    return True
