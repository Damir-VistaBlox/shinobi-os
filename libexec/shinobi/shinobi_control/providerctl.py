"""LLM provider manifests: where a model endpoint is and what it is allowed to see.

A provider manifest answers three questions, and nothing else:

  * where the endpoint is (`base_url`),
  * which wire protocol speaks to it (`api`),
  * whether engagement data sent there leaves this machine (`egress`).

That third field is the reason this is a governed registry rather than a
config file. `cloud` means client data crosses the network, and it is the
field the egress gate in `scope.py` will check against an engagement's written
clearance before anything is sent. A manifest that does not classify itself is
refused rather than defaulted, so adding a provider cannot quietly opt it into
egress. `local` is for endpoints that do not leave the machine -- localhost, a
LAN host the operator controls, an Ollama daemon.

This is a second registry, deliberately not merged into `tools/*.toml`. That
file's loader describes recon tools, this describes model endpoints, and they
ship in different packages that cannot import each other. The tool registry
already draws the same line in its own docstring, and the field names differ
enough (`egress` vs `risk`, `base_url` vs `binary`) that merging them would
produce a schema that describes neither well.

The schema differs from `tools/*.toml` in one visible way: `models` is a real
TOML array rather than a comma-separated scalar. The tool manifests happen to
be flat because no field of theirs needs a list; that is incidental, not a
principle, and a model catalogue read as a single string is worse to write and
worse to validate.

Keys are not in this file and cannot be. `credentials.py` stores them per user
under the state directory, reached by the manifest's `id`; the manifest holds
no field that could carry a secret. That is why a provider is described in two
places: the packaged, world-readable policy here, and the operator's private
credential there.
"""
from __future__ import annotations

import ipaddress
import os
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

# The provider id grammar is owned by the credential store, not restated here.
# A manifest that accepted an id the store would then refuse would let a
# provider load and be listed, then fail on first use; keeping one definition
# means an id that is storable is also an id that is loadable.
from .credentials import PROVIDER_ID_RE as _CREDENTIAL_ID_RE

# Wire protocols. Each names a request shape, not a vendor: `openai-compatible`
# is the escape hatch that covers the large majority of hosted providers
# without a hand-written adapter each, and it is why "any API key" is a
# manifest away rather than a code change away.
APIS = frozenset({"openai", "openai-compatible", "anthropic"})

# Where the data goes. Closed set: a provider must classify itself.
EGRESS = frozenset({"local", "cloud"})

PROVIDER_ID_RE = _CREDENTIAL_ID_RE

# Metadata endpoints. A cloud provider is never legitimately reached at one of
# these, and an LLM client that can be pointed anywhere can be pointed at
# 169.254.169.254 to trade the instance's own credentials for a working
# provider key. Refused by address below, not by name, because the name is not
# the problem -- the address is.
_LINK_LOCAL = ipaddress.ip_network("169.254.0.0/16")

_REQUIRED_FIELDS = (
    "id",
    "name",
    "api",
    "base_url",
    "egress",
    "requires_key",
)

_OPTIONAL_FIELDS = ("models", "default_model", "reachable_on")

# Model ids are vendor-defined, so this stays permissive: it forbids whitespace
# and the characters that would break a request line, not the alphabet.
_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")

# Deliberately stricter than RFC 1123: a peer declaration is not a place to
# accept unicode or a bare underscore, and anything that fails this should be
# written as a numeric address instead.
_HOSTNAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")


class ProviderError(RuntimeError):
    """Raised when the provider registry is missing, malformed or inconsistent."""


@dataclass(frozen=True)
class Provider:
    id: str
    name: str
    api: str
    base_url: str
    egress: str
    requires_key: bool
    models: tuple[str, ...]
    default_model: str
    reachable_on: tuple[str, ...]
    source: Path

    @property
    def local(self) -> bool:
        return self.egress == "local"

    @classmethod
    def parse(cls, data: object, source: Path) -> "Provider":
        if not isinstance(data, dict):
            raise ProviderError(f"{source}: manifest must be a table")

        missing = [field for field in _REQUIRED_FIELDS if field not in data]
        if missing:
            raise ProviderError(f"{source}: missing required field(s): {', '.join(missing)}")
        unknown = sorted(set(data) - set(_REQUIRED_FIELDS) - set(_OPTIONAL_FIELDS))
        if unknown:
            # Same reason as the tool registry: a typo'd field would read as
            # "not set" and silently drop a restriction. That is how a provider
            # ends up unclassified, or local, when it was meant to be neither.
            raise ProviderError(f"{source}: unknown field(s): {', '.join(unknown)}")

        for field in ("id", "name", "api", "base_url", "egress"):
            if not isinstance(data[field], str) or not data[field].strip():
                raise ProviderError(f"{source}: {field} must be a non-empty string")

        provider_id = data["id"]
        if not PROVIDER_ID_RE.fullmatch(provider_id):
            raise ProviderError(
                f"{source}: id must match {PROVIDER_ID_RE.pattern}, got {provider_id!r}"
            )

        if data["api"] not in APIS:
            raise ProviderError(f"{source}: api must be one of {sorted(APIS)}, got {data['api']!r}")
        if data["egress"] not in EGRESS:
            raise ProviderError(
                f"{source}: egress must be one of {sorted(EGRESS)}, got {data['egress']!r}. "
                "A provider must say whether engagement data sent here leaves the machine."
            )
        if not isinstance(data["requires_key"], bool):
            raise ProviderError(f"{source}: requires_key must be a boolean")

        base_url = _validate_base_url(data["base_url"], data["egress"], source)

        models = _validate_models(data["models"], source) if "models" in data else ()
        if "default_model" in data:
            default_model = data["default_model"]
            if not isinstance(default_model, str) or not default_model.strip():
                raise ProviderError(f"{source}: default_model must be a non-empty string")
            if models and default_model not in models:
                raise ProviderError(f"{source}: default_model {default_model!r} is not in models")
        else:
            default_model = models[0] if models else ""

        if not default_model:
            # A provider that will be asked for a model has to be able to answer
            # without being told which one, or every caller invents its own.
            raise ProviderError(
                f"{source}: a provider needs models, or a default_model, so a model can be chosen"
            )

        if "reachable_on" in data:
            if data["egress"] == "cloud":
                # Refused rather than ignored. A field that is accepted on a
                # manifest and never read is a field an operator will believe is
                # constraining something, and the belief is the vulnerability.
                raise ProviderError(
                    f"{source}: reachable_on applies to local providers only; a cloud "
                    "provider is governed by the engagement clearance check instead"
                )
            reachable_on = _validate_reachable_on(data["reachable_on"], source)
        elif data["egress"] == "local":
            raise ProviderError(
                f"{source}: a local provider must declare reachable_on. \"local\" is what "
                "waives cloud clearance, so it has to say where local means."
            )
        else:
            reachable_on = ()

        return cls(
            id=provider_id,
            name=data["name"],
            api=data["api"],
            base_url=base_url,
            egress=data["egress"],
            requires_key=data["requires_key"],
            models=models,
            default_model=default_model,
            reachable_on=reachable_on,
            source=source,
        )


def _validate_base_url(value: str, egress: str, source: Path) -> str:
    """Reject an endpoint that is malformed, or unsafe for its declared egress.

    The cloud rules are the ones that matter. A cloud provider reached over
    plain HTTP puts the API key and every prompt on the wire in clear, and a
    cloud endpoint that resolves to a private or link-local address is either a
    mistake or an attempt to have this process read instance metadata and post
    it somewhere. Both are refused at load time.

    This is a load-time check, and it is not the whole defence: a hostname can
    resolve to a loopback address now and a different one at request time, so
    anything that actually sends a request must resolve and re-check the
    address again. That belongs to the egress gate, which is the only code here
    that opens a connection. What this catches is the manifest that is wrong on
    its face -- a typo, a stray loopback, a cloud endpoint written as
    http:// -- which is the mistake that would otherwise be discovered by
    leaking.
    """
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ProviderError(
            f"{source}: base_url must be an http(s) URL with a host, got {value!r}"
        )
    if parsed.username or parsed.password:
        raise ProviderError(
            f"{source}: base_url must not embed credentials; the API key is stored separately"
        )
    if parsed.query or parsed.fragment:
        raise ProviderError(f"{source}: base_url must not carry a query or fragment")

    host = parsed.hostname
    if egress == "cloud":
        if parsed.scheme != "https":
            raise ProviderError(
                f"{source}: a cloud provider must use https; http would put the API key "
                "and every prompt on the wire in clear"
            )
        literal = _as_ip(host)
        if literal is not None and not is_public_address(literal):
            raise ProviderError(
                f"{source}: a cloud provider must not point at {host}, which is not a "
                "public address"
            )
    else:
        # A local endpoint may legitimately be plain HTTP on a private address,
        # so the only hard rule is that a cloud endpoint is never silently
        # downgraded to local by writing a private address here. That is the
        # operator's call to make explicitly, in a field named for it.
        literal = _as_ip(host)
        if literal is not None and literal.is_global and parsed.scheme == "http":
            raise ProviderError(
                f"{source}: a local provider over plain HTTP must not point at the public "
                f"address {host}; use https, or declare egress = \"cloud\""
            )
    return value.rstrip("/")


def _as_ip(host: str):
    candidate = host.strip("[]")
    try:
        return ipaddress.ip_address(candidate)
    except ValueError:
        return None


def is_public_address(address) -> bool:
    if address.is_loopback or address.is_private or address.is_link_local:
        return False
    if address in _LINK_LOCAL:
        return False
    if address.is_reserved or address.is_multicast or address.is_unspecified:
        return False
    return address.is_global


def _validate_reachable_on(value, source: Path) -> tuple[str, ...]:
    """Validate the declared local peers of a `local` provider.

    Required for every local provider, because "local" is the field that waives
    cloud clearance. Without a declared peer set, `egress = "local"` plus a
    hostname that resolves off-box is a way to skip the egress gate while
    sending engagement data to a third party -- the DNS-name case that a
    literal-address check cannot see. Naming the expected peers lets the
    connection-time check in the egress gate refuse the mismatch.
    """
    if not isinstance(value, list) or not value:
        raise ProviderError(
            f"{source}: reachable_on must be a non-empty array of hosts or addresses"
        )
    peers: list[str] = []
    for entry in value:
        if not isinstance(entry, str) or not entry.strip():
            raise ProviderError(f"{source}: reachable_on entries must be non-empty strings")
        host = entry.strip()
        literal = _as_ip(host)
        if literal is None and not _HOSTNAME_RE.fullmatch(host):
            raise ProviderError(f"{source}: {host!r} in reachable_on is not a host or address")
        if literal is not None and is_public_address(literal):
            # A local provider that names a public address as its peer is asking
            # to skip the clearance check for an off-box destination. An operator
            # who genuinely wants that is describing a cloud provider, and the
            # honest spelling of that is the field the gate reads.
            raise ProviderError(
                f"{source}: reachable_on lists the public address {host}. A local provider's "
                "peers must be on this machine or the local network."
            )
        if literal is not None and (literal.is_link_local or literal in _LINK_LOCAL):
            # The metadata endpoint is not a model server. Allowing it here
            # would let a manifest that calls itself local point at the
            # instance's own credentials and treat whatever comes back as a
            # local model, which is exfiltration wearing a "local" label.
            raise ProviderError(
                f"{source}: reachable_on lists {host}, a link-local address. A local "
                "provider's peers must be on this machine or the local network."
            )
        if host in peers:
            raise ProviderError(f"{source}: reachable_on lists {host!r} twice")
        peers.append(host)
    return tuple(peers)


def _validate_models(value, source: Path) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise ProviderError(f"{source}: models must be a non-empty array of model ids")
    models: list[str] = []
    for entry in value:
        if not isinstance(entry, str) or not _MODEL_RE.match(entry):
            raise ProviderError(f"{source}: {entry!r} is not a usable model id")
        if entry in models:
            raise ProviderError(f"{source}: model {entry!r} is listed twice")
        models.append(entry)
    return tuple(models)


def provider_dirs() -> list[Path]:
    """Every directory searched for manifests, lowest precedence first.

    Layered on purpose. `openai-compatible` is a protocol, not an endpoint, so
    the interesting providers are the ones nobody can ship in advance: a
    self-hosted vLLM, a corporate gateway, a regional cloud endpoint. Requiring
    a repackaged ISO to add one would make the escape hatch unusable, so
    `/etc/shinobi/providers.d` takes operator manifests and the packaged
    directory supplies the defaults. A duplicate id across layers is an error
    rather than a silent win for one of them, so an operator addition that
    shadows a packaged provider is visible instead of mysterious.

    `SHINOBI_PROVIDERS_DIR` replaces the search entirely, which is what tests
    and a pinned deployment want.
    """
    override = os.environ.get("SHINOBI_PROVIDERS_DIR", "").strip()
    if override:
        return [Path(override).expanduser()]

    dirs = [Path("/etc/shinobi/providers.d"), Path("/usr/share/shinobi/providers")]
    source_tree = Path(__file__).resolve().parents[3] / "providers"
    if not any(d.is_dir() for d in dirs):
        # Not installed: fall back to the checkout so the ISO, a dev tree, and
        # a live session all read the same manifests the tests read.
        dirs.append(source_tree)
    return dirs


def load_all(directories: list[str | os.PathLike[str]] | None = None) -> dict[str, Provider]:
    """Load every manifest, keyed by provider id.

    All-or-nothing, for the reason the tool registry is: a registry that loads
    partially is worse than one that refuses, because the caller cannot tell
    which providers are governed. A malformed manifest here means a provider an
    operator expected to be available is not, loudly, rather than a provider
    that failed open.
    """
    roots = [Path(d) for d in directories] if directories is not None else provider_dirs()
    existing = [root for root in roots if root.is_dir()]
    if not existing:
        raise ProviderError(
            "no provider manifest directory found; looked in "
            + ", ".join(str(root) for root in roots)
        )

    providers: dict[str, Provider] = {}
    for root in existing:
        for path in sorted(root.glob("*.toml")):
            try:
                with path.open("rb") as handle:
                    data = tomllib.load(handle)
            except (OSError, tomllib.TOMLDecodeError) as exc:
                raise ProviderError(f"{path}: cannot read manifest ({exc})") from exc
            provider = Provider.parse(data, path)
            if provider.id in providers:
                other = providers[provider.id].source
                raise ProviderError(
                    f"{path}: id {provider.id!r} is already claimed by {other}"
                )
            providers[provider.id] = provider
    return providers


def get(provider_id: str, directories: list[str | os.PathLike[str]] | None = None) -> Provider:
    """Return a provider manifest, or raise."""
    providers = load_all(directories)
    try:
        return providers[provider_id]
    except KeyError:
        raise ProviderError(f"no provider manifest for {provider_id!r}") from None


def main() -> int:
    from . import credentials

    action = sys.argv[1] if len(sys.argv) > 1 else "list"
    as_json = "--json" in sys.argv[2:]

    if action in {"help", "-h", "--help"}:
        print(
            "Usage: shinobi provider <list|inspect|check|key|forget> [id] [--json]\n"
            "\n"
            "  list            every provider, with whether a key is stored\n"
            "  inspect <id>    one manifest, verbatim\n"
            "  check           validate every manifest and report\n"
            "  key <id>        store an API key, read from a prompt or stdin\n"
            "  forget <id>     remove the stored key\n"
            "\n"
            "Keys are never accepted as arguments, never printed, and never written\n"
            "to a manifest. On the live image they live in the kernel keyring and do\n"
            "not survive a reboot."
        )
        return 0

    if action == "list":
        try:
            providers = load_all()
        except ProviderError as exc:
            print(f"shinobi-provider: {exc}", file=sys.stderr)
            return 1
        rows = []
        for provider in providers.values():
            rows.append(
                {
                    "id": provider.id,
                    "name": provider.name,
                    "api": provider.api,
                    "egress": provider.egress,
                    "default_model": provider.default_model,
                    "requires_key": provider.requires_key,
                    "has_key": credentials.has_key(provider.id) if provider.requires_key else True,
                }
            )
        if as_json:
            import json

            print(json.dumps({"providers": rows}, sort_keys=True))
        else:
            print(f"{'ID':28} {'API':18} {'EGRESS':6} {'KEY':5} DEFAULT MODEL")
            for row in rows:
                key = "yes" if row["has_key"] else "no"
                # A cloud provider with no key is listed as such rather than
                # hidden: the operator needs to see it exists and is not ready.
                marker = " " if row["has_key"] else "!"
                print(
                    f"{marker}{row['id']:27} {row['api']:18} {row['egress']:6} "
                    f"{key:5} {row['default_model']}"
                )
        return 0

    if action == "inspect":
        provider_id = sys.argv[2] if len(sys.argv) > 2 else ""
        if not provider_id:
            print("usage: shinobi provider inspect <id>", file=sys.stderr)
            return 2
        try:
            provider = get(provider_id)
        except ProviderError as exc:
            print(f"shinobi-provider: {exc}", file=sys.stderr)
            return 1
        print(provider.source.read_text(), end="")
        return 0

    if action == "check":
        try:
            providers = load_all()
        except ProviderError as exc:
            print(f"shinobi-provider: {exc}", file=sys.stderr)
            return 1
        print(f"{len(providers)} provider manifest(s) valid")
        for root in provider_dirs():
            print(f"  search path: {root}{'' if root.is_dir() else ' (absent)'}")
        for provider in providers.values():
            print(f"  {provider.id:28} {provider.egress:6} {provider.base_url}")
        return 0

    if action == "key":
        provider_id = sys.argv[2] if len(sys.argv) > 2 else ""
        if not provider_id:
            print("usage: shinobi provider key <id>", file=sys.stderr)
            return 2
        try:
            provider = get(provider_id)
        except ProviderError as exc:
            print(f"shinobi-provider: {exc}", file=sys.stderr)
            return 1
        if not provider.requires_key:
            print(
                f"shinobi-provider: {provider_id} declares requires_key = false and takes no key",
                file=sys.stderr,
            )
            return 1
        # Read from a prompt when interactive, from stdin otherwise, so the key
        # can be piped from a secret manager without ever appearing in argv or
        # in the shell history.
        if sys.stdin.isatty():
            import getpass

            secret = getpass.getpass(f"API key for {provider_id}: ")
        else:
            secret = sys.stdin.read()
        try:
            used = credentials.set_key(provider_id, secret)
        except credentials.CredentialError as exc:
            print(f"shinobi-provider: {exc}", file=sys.stderr)
            return 1
        print(f"shinobi-provider: stored the key for {provider_id} in the {used} backend")
        if used == "keyring":
            print("  it is held in kernel memory and will not survive a reboot")
        return 0

    if action == "forget":
        provider_id = sys.argv[2] if len(sys.argv) > 2 else ""
        if not provider_id:
            print("usage: shinobi provider forget <id>", file=sys.stderr)
            return 2
        try:
            removed = credentials.forget_key(provider_id)
        except credentials.CredentialError as exc:
            print(f"shinobi-provider: {exc}", file=sys.stderr)
            return 1
        print(
            f"shinobi-provider: removed the key for {provider_id}"
            if removed
            else f"shinobi-provider: no key stored for {provider_id}"
        )
        return 0

    raise SystemExit(f"unknown provider action: {action}")


if __name__ == "__main__":
    raise SystemExit(main())
