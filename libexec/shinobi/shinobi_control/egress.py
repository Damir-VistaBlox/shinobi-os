"""The egress gate: may this prompt go to this provider, in this engagement?

Everything else in Shinobi governs *tools acting on targets*. This governs the
opposite direction -- engagement data leaving the machine -- and it is a
separate question with a separate failure mode. A prompt can carry a
client-confidential target list, live scan output, or a credential that no
scope check will ever look at, because the scope gate is asked "is this host
authorized?" and never "where does this text go?".

So this module answers one question, fail-closed, before any network I/O:

    may this exact prompt be sent to this exact provider and model, right now?

Three independent things have to line up, and the order matters:

  1. the engagement must permit this egress at all, in writing, in scope.yaml;
  2. the provider manifest must classify its own egress, and a `local` one must
     still be talking to the peer it declared;
  3. cloud egress additionally needs a human approval bound to this prompt's
     digest -- standing clearance is not enough, because standing clearance
     would let the agent send *anything* at any time, which is the leak.

The prompt is hashed, never stored. `prompt_digest` is the only representation
of the text that reaches disk, argv, the approval, or the audit trail, so an
operator reviewing what left the machine sees a digest they can correlate but
not reconstruct, and an approval can be bound to "this prompt" without the
approval file becoming a copy of it.

Nothing here opens a connection. The gate hands back a Decision and the caller
performs the request; `finish()` records the outcome. That split is what lets
the intent record be written *before* the request, so a client that crashes
mid-call still leaves evidence that it tried.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import ipaddress
import json
import os
import re
import socket
import stat
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from . import audit
from .approval import ApprovalError, consume as consume_approval
from .policy import current_profile
from .providerctl import Provider, ProviderError, get as get_provider, load_all as load_providers

# The capability an approval is granted under. Not a control-plane capability
# and deliberately not registered as one: that registry's entries are things
# the daemon can be asked to *execute*, and an LLM call is not something a
# socket client should be able to trigger by name. This gate is a library the
# client calls in-process, and it makes its own decision.
EGRESS_CAPABILITY = "llm.egress"

# Kept in step with validate_name() in bin/shinobi-engagement and
# _ENGAGEMENT_NAME_RE in shinobi_recon/scope.py.
_ENGAGEMENT_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")

# Profiles permitted to move engagement data off this machine. Sending a
# client's scan data to a third party is a privileged act in the same sense
# that running a privileged tool is, and the profile ladder should say so
# rather than letting an `observer` session exfiltrate by asking a model a
# question. Profiles are not ordered in policy.py, so the ladder is spelled out
# here rather than inferred from the set.
_CLOUD_PROFILES = ("operator", "administrator", "emergency")

_LLM_KEYS = frozenset({"cloud", "providers", "models"})


class EgressRefused(RuntimeError):
    """Raised when a prompt may not be sent. Never raised after a refusal is
    logged -- the caller is expected to have recorded the attempt already."""


@dataclass(frozen=True)
class Clearance:
    """What an engagement has authorized in writing.

    `providers` and `models` are None for "no additional restriction" and a
    tuple otherwise. An explicitly empty tuple means *nothing* is allowed,
    which is the fail-closed reading: someone who writes `providers: []`
    expecting a placeholder has said no, not nothing.
    """

    cloud: bool
    providers: tuple[str, ...] | None
    models: tuple[str, ...] | None

    @property
    def local(self) -> bool:
        return True


def registry_summary() -> dict[str, dict[str, Any]]:
    """Every known provider, for `shinobi egress show`.

    Includes providers this engagement could not use. The point of the command
    is to answer "what could I use, and what would it cost me", and a provider
    hidden because it is not cleared is exactly the one an operator needs to
    know is off the table.
    """
    return {
        provider.id: {
            "egress": provider.egress,
            "api": provider.api,
            "base_url": provider.base_url,
            "default_model": provider.default_model,
            "requires_key": provider.requires_key,
        }
        for provider in sorted(load_providers().values(), key=lambda p: p.id)
    }


@dataclass(frozen=True)
class Decision:
    """A cleared request. Carries everything the caller needs, and nothing
    that would put the prompt back into a log."""

    call_id: str
    engagement: str
    provider: Provider
    model: str
    prompt_sha256: str
    peer: str
    approval_id: str

    @property
    def egress(self) -> str:
        return self.provider.egress

    @property
    def requires_key(self) -> bool:
        return self.provider.requires_key


def prompt_digest(prompt: str, system: str | None = None) -> str:
    """A stable digest of a prompt, safe to put in an approval or an audit log.

    The version tag is inside the hashed payload so a future change to what gets
    hashed cannot silently produce digests that look comparable to today's but
    are not. Canonical JSON matches audit.py's form, so the same request hashed
    by either path produces the same value.
    """
    if not isinstance(prompt, str):
        raise EgressRefused("prompt must be a string")
    payload = {"v": 1, "prompt": prompt, "system": system or ""}
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest()


# --------------------------------------------------------------------------
# Engagement resolution
#
# Duplicated from shinobi_recon/scope.py and evidencectl.py rather than
# imported. The MCP server and the control plane ship as separate packages and
# cannot import each other; evidencectl.py already carries this same duplication
# for the same reason. The rule is that the engagement is found by name inside
# the engagements root, SHINOBI_ENGAGEMENT_DIR is ignored, and the result must
# be a real directory sitting directly inside that root.
# --------------------------------------------------------------------------


def engagements_root() -> Path:
    root = os.environ.get("SHINOBI_ENGAGEMENTS_DIR", "").strip()
    if not root:
        base = os.environ.get("XDG_DATA_HOME", "").strip() or str(Path.home() / ".local" / "share")
        root = str(Path(base) / "shinobi" / "engagements")
    return Path(root).expanduser()


def _engagement_dir() -> Path:
    name = os.environ.get("SHINOBI_ENGAGEMENT", "").strip()
    if not name:
        # The daemon is not launched per-engagement, so fall back to the state
        # file the CLI writes, as policy.current_engagement() does.
        state = (
            Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
            / "shinobi/current-engagement"
        )
        try:
            name = state.read_text(encoding="utf-8").strip()
        except OSError:
            name = ""
    if not name:
        raise EgressRefused(
            "no active engagement. Run 'shinobi engagement use <name>' first: "
            "egress clearance is per-engagement, so there is nothing to check against."
        )
    if not _ENGAGEMENT_NAME_RE.fullmatch(name):
        raise EgressRefused(f"refusing malformed engagement name {name!r}")

    root = engagements_root()
    candidate = root / name
    if candidate.is_symlink():
        raise EgressRefused(f"refusing symlinked engagement directory: {candidate}")
    try:
        resolved_root = root.resolve(strict=True)
    except OSError as exc:
        raise EgressRefused(f"engagements root {root} is unusable: {exc}") from exc
    resolved = candidate.resolve()
    if resolved.parent != resolved_root:
        raise EgressRefused(
            f"engagement {name!r} resolves to {resolved}, which is outside "
            f"{resolved_root}. Refusing."
        )
    if not resolved.is_dir():
        raise EgressRefused(f"no engagement directory at {resolved}")
    return resolved


# --------------------------------------------------------------------------
# scope.yaml
# --------------------------------------------------------------------------


def load_scope(engagement_dir: Path) -> dict[str, Any]:
    """Read scope.yaml with the same hardening the MCP gate applies.

    The scope file *is* the authorization, so it must be a plain file owned by
    whoever runs the tools: a symlink could point it elsewhere, and a file
    writable by group or other could have been edited by someone who is not the
    operator -- at which point the clearance in it is not the operator's.

    Every failure raises EgressRefused. A bare yaml or OSError escaping here
    would skip the audit record, and an unlogged refusal is the one outcome an
    audit trail cannot survive.
    """
    path = engagement_dir / "scope.yaml"
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise EgressRefused(f"no scope file at {path}") from exc
    except OSError as exc:
        raise EgressRefused(f"cannot read scope file {path}: {exc}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise EgressRefused(f"refusing scope file {path}: not a regular file")
    if info.st_mode & 0o022:
        raise EgressRefused(
            f"refusing scope file {path}: writable by group or other "
            f"(mode {stat.filemode(info.st_mode)}). Run 'chmod go-w {path}' to fix."
        )
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise EgressRefused(f"cannot read scope file {path}: {exc}") from exc
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise EgressRefused(f"scope file {path} is not valid YAML: {exc}. Refusing.") from exc
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise EgressRefused(
            f"scope file {path} must contain a mapping at the top level, "
            f"got {type(data).__name__}. Refusing."
        )
    return data


def clearance(scope: dict[str, Any]) -> Clearance:
    """Read the `llm:` block. Absent, malformed, or misspelled means no cloud.

    Only this one namespace is validated. The rest of scope.yaml is the MCP
    gate's business and it tolerates keys it does not know; making the whole
    file strict here would refuse real engagements for unrelated additions.

    An absent block denies cloud. That is the whole reason this function exists:
    an engagement created before this feature existed, or one whose author never
    considered the question, must not start sending its client's data to a
    third party because nobody wrote anything down.
    """
    block = scope.get("llm")
    if block is None:
        return Clearance(cloud=False, providers=None, models=None)
    if not isinstance(block, dict):
        raise EgressRefused(
            f"scope llm: must be a mapping, got {type(block).__name__}. Refusing."
        )
    unknown = sorted(set(block) - _LLM_KEYS)
    if unknown:
        # Refused rather than ignored, for the same reason the provider loader
        # refuses unknown fields: `cloudd: true` must not read as "unset" and
        # inherit the permissive reading.
        raise EgressRefused(
            f"scope llm: unknown field(s): {', '.join(unknown)}. "
            f"Known fields are: {', '.join(sorted(_LLM_KEYS))}."
        )

    cloud = block.get("cloud", False)
    if not isinstance(cloud, bool):
        raise EgressRefused(
            f"scope llm: cloud must be true or false, got {cloud!r}. Refusing."
        )

    return Clearance(
        cloud=cloud,
        providers=_allowlist(block, "providers"),
        models=_allowlist(block, "models"),
    )


def _allowlist(block: dict[str, Any], key: str) -> tuple[str, ...] | None:
    """An allowlist is either absent (no restriction) or an exact set.

    Absent and empty are different on purpose. `providers: []` says "none of
    these", which is the reading that survives someone writing an empty list as
    a placeholder and then being surprised that nothing works -- the failure is
    loud and local, rather than a silently unrestricted provider.
    """
    if key not in block:
        return None
    value = block[key]
    if not isinstance(value, list):
        raise EgressRefused(f"scope llm: {key} must be a list, got {type(value).__name__}")
    entries: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise EgressRefused(f"scope llm: {key} entries must be non-empty strings")
        if item in entries:
            raise EgressRefused(f"scope llm: {key} lists {item!r} twice")
        entries.append(item)
    return tuple(entries)


# --------------------------------------------------------------------------
# Peer resolution
# --------------------------------------------------------------------------


def _resolve(host: str, port: int) -> set[str]:
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise EgressRefused(f"cannot resolve {host}: {exc}") from exc
    return {info[4][0] for info in infos}


def check_local_peer(provider: Provider) -> str:
    """Confirm a `local` provider is really talking to the peers it declared.

    This is the request-time half of the check the manifest loader cannot do.
    The loader reads a hostname; this resolves it. A name that resolved to
    loopback when the manifest was written and to a public address now is the
    DNS-rebinding case, and the only place it can be caught is at connect time.

    Every resolved address must be inside the declared set, not merely one of
    them: a name that resolves to both 127.0.0.1 and a public address is not a
    local provider, and accepting it because one answer looked right is exactly
    the mistake.
    """
    from urllib.parse import urlparse

    parsed = urlparse(provider.base_url)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    actual = _resolve(parsed.hostname, port)
    if not actual:
        raise EgressRefused(f"{provider.id}: {parsed.hostname} resolved to no addresses")

    allowed: set[str] = set()
    for entry in provider.reachable_on:
        literal = _as_ip(entry)
        if literal is not None:
            allowed.add(str(literal))
            continue
        try:
            allowed |= _resolve(entry, port)
        except EgressRefused:
            # A declared peer that will not resolve cannot be vouched for.
            raise EgressRefused(
                f"{provider.id}: declared peer {entry!r} does not resolve, so it cannot "
                "be confirmed as local"
            ) from None

    outside = sorted(addr for addr in actual if addr not in allowed)
    if outside:
        raise EgressRefused(
            f"{provider.id}: {parsed.hostname} resolves to {', '.join(sorted(actual))}, "
            f"which is outside the peers this manifest declared ({', '.join(provider.reachable_on)}). "
            "Refusing: a local provider that reaches off-box skips the clearance check."
        )
    return sorted(actual)[0]


def _as_ip(host: str):
    try:
        return ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Audit
# --------------------------------------------------------------------------


def _engagement_log(engagement_dir: Path):
    return engagement_dir / "log.jsonl"


def _write_log(
    engagement_dir: Path | None,
    entry: dict[str, Any],
) -> None:
    """Append one record, fsynced.

    Mirrors the record shape shinobi_recon.scope.log_call writes, so one
    engagement's log stays uniform whether the line came from a tool call or
    from an egress decision.

    With no engagement there is nowhere safe to write, so it goes to stderr --
    specifically stderr, because the MCP server speaks JSON-RPC on stdout and
    a bare line there corrupts the transport.
    """
    line = json.dumps(entry, sort_keys=True)
    if engagement_dir is None:
        print(f"shinobi-egress: {line}", file=sys.stderr, flush=True)
        return
    path = _engagement_log(engagement_dir)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(line + "\n")
        stream.flush()
        # The intent record has to outlive the request, including a hard kill.
        os.fsync(stream.fileno())


def _record(
    engagement_dir: Path | None,
    *,
    call_id: str,
    phase: str,
    provider: str,
    model: str,
    verdict: str,
    digest: str,
    egress: str,
    detail: str = "",
) -> None:
    _write_log(
        engagement_dir,
        {
            "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "call_id": call_id,
            "phase": phase,
            "tool": EGRESS_CAPABILITY,
            "target": provider,
            # args carries the digest, never the prompt. The field name is kept
            # so a log reader sees the same shape as a tool call's.
            "args": [f"model={model}", f"prompt_sha256={digest}"],
            "verdict": verdict,
            "detail": detail[:2000],
            "egress": egress,
        },
    )


def _refused(
    engagement_dir: Path | None,
    *,
    call_id: str,
    provider: str,
    model: str,
    digest: str,
    egress: str,
    reason: str,
) -> EgressRefused:
    """Record a refusal in both trails, then return it to be raised.

    Both, not either. The engagement log is the client's record of what it
    tried; the control-plane audit is the operator's record of what the system
    did about it. A refusal that appears in only one of them is a question
    somebody will later have to guess the answer to.
    """
    _record(
        engagement_dir,
        call_id=call_id,
        phase="result",
        provider=provider,
        model=model,
        verdict="refused",
        digest=digest,
        egress=egress,
        detail=reason,
    )
    try:
        audit.write(
            actor=os.environ.get("USER", "") or "unknown",
            capability=EGRESS_CAPABILITY,
            arguments={"prompt_sha256": digest, "provider": provider, "model": model},
            status="refused",
            detail=reason,
            references={"prompt_sha256": digest, "call_id": call_id},
        )
    except OSError:
        # The engagement log already has the refusal. A failure to reach the
        # second trail must not turn a refusal into an unhandled crash, which
        # would look like a successful call to anything watching the exit code.
        pass
    return EgressRefused(reason)


# --------------------------------------------------------------------------
# The gate
# --------------------------------------------------------------------------


def authorize(
    provider_id: str,
    prompt: str,
    *,
    model: str | None = None,
    system: str | None = None,
    approval_id: str | None = None,
) -> Decision:
    """Decide whether this prompt may be sent, and record that a request was made.

    Returns a Decision on success. Raises EgressRefused otherwise, having first
    written a refusal to both audit trails.

    The order of the checks is the design. Cheap local facts (does the
    engagement exist, is its scope file trustworthy, does the manifest parse)
    come first because they are the ones that fail on a typo. The approval is
    consumed *last*, immediately before returning, so an approval is never spent
    on a call that was going to be refused anyway.
    """
    call_id = uuid.uuid4().hex[:16]
    engagement_dir: Path | None = None
    provider_name = provider_id
    model_name = model or ""
    egress = "unknown"

    # A prompt that is not a string is a caller bug, but it is still an attempt
    # to reach a provider and it still has to leave a record. Digesting first and
    # carrying the failure forward keeps it on the audited path instead of
    # letting it escape before anything is written -- an unlogged refusal is the
    # one outcome an audit trail cannot recover from.
    try:
        digest = prompt_digest(prompt, system)
    except EgressRefused as exc:
        digest = ""
        bad_prompt: EgressRefused | None = exc
    else:
        bad_prompt = None

    try:
        engagement_dir = _engagement_dir()
    except EgressRefused as exc:
        raise _refused(
            None,
            call_id=call_id,
            provider=provider_name,
            model=model_name,
            digest=digest,
            egress=egress,
            reason=str(exc),
        ) from None

    engagement_name = engagement_dir.name

    def refuse(reason: str, *, egress_: str = "unknown") -> EgressRefused:
        return _refused(
            engagement_dir,
            call_id=call_id,
            provider=provider_name,
            model=model_name,
            digest=digest,
            egress=egress_,
            reason=f"{reason} (engagement {engagement_name}, provider {provider_name})",
        )

    if bad_prompt is not None:
        raise refuse(str(bad_prompt))

    # 1. The manifest. An unknown or malformed provider is refused before the
    #    scope file is even read: there is no endpoint to have authorized.
    try:
        provider = get_provider(provider_id)
    except ProviderError as exc:
        raise refuse(str(exc)) from None
    egress = provider.egress
    model_name = model or provider.default_model
    if not model_name:
        raise refuse("no model given and the manifest names no default", egress_=egress)
    if provider.models and model_name not in provider.models:
        raise refuse(
            f"model {model_name!r} is not in this manifest's catalogue "
            f"({', '.join(provider.models)})",
            egress_=egress,
        )

    # 2. The engagement's written clearance.
    try:
        allowed = clearance(load_scope(engagement_dir))
    except EgressRefused as exc:
        raise refuse(str(exc), egress_=egress) from None

    if allowed.providers is not None and provider.id not in allowed.providers:
        raise refuse(
            f"provider {provider.id!r} is not permitted by this engagement "
            f"(llm.providers: {', '.join(allowed.providers) or 'nothing'})",
            egress_=egress,
        )
    if allowed.models is not None and model_name not in allowed.models:
        raise refuse(
            f"model {model_name!r} is not permitted by this engagement "
            f"(llm.models: {', '.join(allowed.models) or 'nothing'})",
            egress_=egress,
        )

    # 3. A local provider must still be reaching the peers it declared. This is
    #    resolved here, not at load time, so a rebind is caught.
    peer = ""
    if provider.egress == "local":
        try:
            peer = check_local_peer(provider)
        except EgressRefused as exc:
            raise refuse(str(exc), egress_=egress) from None
    else:
        if not allowed.cloud:
            raise refuse(
                f"{provider.id} is a cloud provider and this engagement has not "
                f"cleared cloud egress. Add 'llm:\\n  cloud: true' to "
                f"{engagement_dir / 'scope.yaml'} if the client has authorized it in writing.",
                egress_=egress,
            )
        profile = current_profile()
        if profile not in _CLOUD_PROFILES:
            raise refuse(
                f"cloud egress needs an operator-or-above trust profile; this "
                f"session is {profile!r}",
                egress_=egress,
            )
        if provider.requires_key:
            # Confirmed, never read: the key itself must not reach this frame
            # any more than the prompt must reach the log.
            from . import credentials

            try:
                present = credentials.has_key(provider.id)
            except Exception:  # noqa: BLE001 - a broker problem must not leak detail
                present = False
            if not present:
                raise refuse(
                    f"no API key stored for {provider.id}. Store one with "
                    f"'shinobi provider key {provider.id}'.",
                    egress_=egress,
                )

    # 4. Cloud egress needs a human decision about *this* prompt. The approval
    #    is bound to the digest, the provider, and the model, so it cannot be
    #    reused for a different prompt or repointed at a cheaper or larger model.
    if provider.egress == "cloud":
        if not approval_id:
            raise refuse(
                "cloud egress requires a human approval for this exact prompt. "
                f"Request one with: shinobi approval request --capability {EGRESS_CAPABILITY} "
                f'--args-json \'{{"prompt_sha256":"{digest}","provider":"{provider.id}",'
                f'"model":"{model_name}"}}\'',
                egress_=egress,
            )
        try:
            consume_approval(
                approval_id,
                capability=EGRESS_CAPABILITY,
                arguments={
                    "prompt_sha256": digest,
                    "provider": provider.id,
                    "model": model_name,
                },
                # Bound to the session that asked, exactly as nmap_scan's
                # approval is. Without it the profile field is recorded and
                # never read, and an approval granted under one profile would
                # be spendable from another.
                profile=current_profile(),
            )
        except (ApprovalError, FileNotFoundError, ValueError) as exc:
            raise refuse(f"approval rejected: {exc}", egress_=egress) from None

    # 5. Record the intent *before* the caller opens a connection, so a client
    #    that dies mid-request still leaves evidence that it tried.
    _record(
        engagement_dir,
        call_id=call_id,
        phase="intent",
        provider=provider.id,
        model=model_name,
        verdict="allowed",
        digest=digest,
        egress=provider.egress,
        detail=f"peer={peer}" if peer else f"base_url={provider.base_url}",
    )

    return Decision(
        call_id=call_id,
        engagement=engagement_name,
        provider=provider,
        model=model_name,
        prompt_sha256=digest,
        peer=peer,
        approval_id=approval_id or "",
    )


def finish(decision: Decision, *, ok: bool, detail: str = "") -> None:
    """Record how the cleared request went.

    Called by the client after the request completes. `detail` is for a short
    outcome note -- a status code, a truncated error -- and must never carry
    prompt text or a response body, because this lands in the log verbatim.
    """
    engagement_dir: Path | None
    try:
        engagement_dir = _engagement_dir()
    except EgressRefused:
        engagement_dir = None
    _record(
        engagement_dir,
        call_id=decision.call_id,
        phase="result",
        provider=decision.provider.id,
        model=decision.model,
        verdict="allowed" if ok else "refused",
        digest=decision.prompt_sha256,
        egress=decision.provider.egress,
        detail=detail,
    )
    try:
        audit.write(
            actor=os.environ.get("USER", "") or "unknown",
            capability=EGRESS_CAPABILITY,
            arguments={
                "prompt_sha256": decision.prompt_sha256,
                "provider": decision.provider.id,
                "model": decision.model,
            },
            status="allowed" if ok else "error",
            detail=detail,
            references={
                "prompt_sha256": decision.prompt_sha256,
                "call_id": decision.call_id,
            },
        )
    except OSError:
        pass
