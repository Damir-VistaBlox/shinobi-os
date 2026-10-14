#!/usr/bin/env python3
"""Build an apt repository for the Shinobi layer, laid over Kali's.

This is an *overlay*, not a fork. The `shinobi-core` package and anything else
this publishes live in a repository listed alongside `kali-rolling`, never in
place of it, because Kali's archive is where the security fixes for the tools
this project exists to expose actually arrive. Forking it would mean owning a
year of kernel, glibc and toolchain CVEs, and a stale fork is still perfectly
installable, which for a pentest distro is the failure that matters.

The index is generated here rather than by `dpkg-scanpackages` or
`apt-ftparchive` so that building a repository needs nothing beyond Python. That
is not cleverness for its own sake: the whole point of this script is that the
layer can be rebuilt on a machine that is not the ISO builder, and a repo you can
only assemble with Debian's archive tooling is a repo you can only assemble in
one place.

Layout produced, the ordinary one:

    dists/kali-shinobi/Release{,.gpg}, InRelease
    dists/kali-shinobi/main/binary-<arch>/Packages{,.gz}

Signing is required unless --allow-unsigned is given, and an unsigned repository
says so on stderr rather than looking like a signed one. An operator who adds
this to their sources without a key gets apt's unsigned-package prompt, which is
the last place to discover it.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import lzma
import os
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

SUITE = "kali-shinobi"
COMPONENT = "main"
REPO_LABEL = "Shinobi OS layer"
# Architectures this repository publishes indexes for. `all` is where an
# Architecture: all package belongs; amd64 is emitted alongside it because the
# pinned and older tooling in the field routinely asks for binary-amd64 and
# silently finds nothing in an index that only exists under binary-all.
ARCHITECTURES = ("all", "amd64", "arm64")


class RepoError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Reading a .deb without dpkg-deb
# ---------------------------------------------------------------------------
#
# A .deb is an `ar` archive holding control.tar.* and data.tar.*. The `ar`
# format is fixed-width 60-byte headers, which is small enough to parse directly
# and means extracting the control metadata -- the only thing an apt index needs
# -- does not require dpkg-deb to be installed.

AR_MAGIC = b"!<arch>\n"


def _ar_entries(blob: bytes):
    """Yield (name, payload) for each member of an ar archive."""
    if not blob.startswith(AR_MAGIC):
        raise RepoError("not an ar archive: a .deb starts with '!<arch>'")
    pos = len(AR_MAGIC)
    while pos + 60 <= len(blob):
        header = blob[pos : pos + 60]
        if header[58:60] != b"`\n":
            raise RepoError("corrupt ar header: missing the 0x60 magic")
        name = header[0:16].decode("ascii", "replace").strip()
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError as exc:
            raise RepoError(f"corrupt ar header for {name!r}") from exc
        pos += 60
        payload = blob[pos : pos + size]
        if len(payload) < size:
            raise RepoError(f"truncated ar archive: {name!r} claims {size} bytes")
        # Members are padded to an even offset.
        pos += size + (size % 2)
        yield name.rstrip("/"), payload


def _decompress(name: str, payload: bytes) -> bytes:
    if name.endswith(".gz"):
        return gzip.decompress(payload)
    if name.endswith(".xz") or name.endswith(".lzma"):
        return lzma.decompress(payload)
    if name.endswith(".zst"):
        # dpkg-deb defaults to zstd on modern Debian. Saying so plainly beats a
        # confusing failure here, and the fix is trivial on the builder.
        raise RepoError(
            f"{name} is zstd-compressed, which Python's stdlib cannot read. "
            "Build the .deb with dpkg-deb -Zzstd, or pass --allow-unsupported."
        )
    return payload


def read_control(deb_path: Path) -> str:
    """Return the Debian control stanza from a .deb, verbatim."""
    try:
        blob = deb_path.read_bytes()
    except OSError as exc:
        raise RepoError(f"{deb_path}: cannot read ({exc})") from exc
    control_member = None
    for name, payload in _ar_entries(blob):
        if name.startswith("control.tar"):
            control_member = (name, payload)
            break
    if control_member is None:
        raise RepoError(f"{deb_path}: no control.tar member; is this really a .deb?")
    name, payload = control_member
    tar_bytes = _decompress(name, payload)
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tar:
        for member in tar.getmembers():
            # Modern dpkg writes "./control"; accept either spelling.
            if member.name.lstrip("./") == "control":
                handle = tar.extractfile(member)
                if handle is None:
                    break
                return handle.read().decode("utf-8", "replace")
    raise RepoError(f"{deb_path}: control.tar has no ./control")


def control_fields(stanza: str) -> dict[str, str]:
    """Parse a control stanza into a dict.

    Folded values are joined with a space, and `Description` keeps its real line
    structure. Both matter: a `Depends:` that wraps onto a second line is common,
    and silently losing the tail produces an index that installs something with
    fewer dependencies than the package declares -- an index that lies, which is
    the one failure mode an overlay repo must not have. And Description is the
    one field whose continuations are *paragraphs*, not one long value, so
    flattening it turns a readable description into a wall of text in
    `apt-cache show`.
    """
    fields: dict[str, str] = {}
    key: str | None = None
    for line in stanza.splitlines():
        if not line.strip():
            break  # end of stanza
        if line[0] in " \t":
            if key is None:
                continue
            if key == "Description":
                fields[key] = fields.get(key, "") + "\n" + line
            else:
                fields[key] = fields.get(key, "") + " " + line.strip()
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        fields[key] = value.strip()
    return fields


# ---------------------------------------------------------------------------
# Index generation
# ---------------------------------------------------------------------------


def _checksums(data: bytes) -> dict[str, str]:
    return {
        "MD5sum": hashlib.md5(data).hexdigest(),
        "SHA1": hashlib.sha1(data).hexdigest(),
        "SHA256": hashlib.sha256(data).hexdigest(),
    }


def packages_stanza(deb_path: Path, pool_prefix: str, fields: dict[str, str]) -> str:
    """One Packages entry: the package's own control fields plus archive facts."""
    data = deb_path.read_bytes()
    sums = _checksums(data)
    # Fixed field order, rather than dict iteration order: two builds of the
    # same package should produce byte-identical indexes, and an index that
    # reshuffles between builds makes every diff look like a real change.
    lines: list[str] = []
    for name in ("Package", "Source", "Version", "Installed-Size", "Maintainer",
                 "Architecture", "Depends", "Recommends", "Suggests", "Conflicts",
                 "Breaks", "Replaces", "Provides", "Section", "Priority",
                 "Homepage", "License", "Vendor"):
        if fields.get(name):
            lines.append(f"{name}: {fields[name]}")
    for name, algo in (("MD5sum", "MD5sum"), ("SHA1", "SHA1"), ("SHA256", "SHA256")):
        lines.append(f"{name}: {sums[algo]}")
    lines.append(f"Filename: {pool_prefix}/{deb_path.name}")
    lines.append(f"Size: {len(data)}")
    # Description last, verbatim, because it is the only field allowed to carry
    # continuation lines and apt expects it there.
    description = fields.get("Description")
    if description:
        lines.append(f"Description: {description}")
    lines.append("")
    return "\n".join(lines)


def build_indexes(repo: Path, debs: list[Path], arches: tuple[str, ...]) -> dict[str, Path]:
    """Write Packages(.gz) for every arch, returning the files written."""
    written: dict[str, Path] = {}
    pool = repo / "pool" / "main"
    pool.mkdir(parents=True, exist_ok=True)

    # One index body, reused across arches: every package here is Architecture:
    # all, and duplicating per-arch would only mean the same stanza could drift
    # between two copies of itself.
    body: list[str] = []
    for deb in sorted(debs):
        fields = control_fields(read_control(deb))
        if fields.get("Architecture", "all") != "all":
            # A natively-compiled package cannot be mirrored into every arch's
            # index; it belongs in its own arch directory only. Refusing here is
            # better than an index that offers an amd64 .deb to an arm64 host.
            raise RepoError(
                f"{deb.name} is Architecture: {fields.get('Architecture')}; "
                "this repository only publishes Architecture: all packages"
            )
        shutil.copy2(deb, pool / deb.name)
        body.append(packages_stanza(deb, f"pool/main", fields))
    index = "\n".join(body)
    if not index.endswith("\n"):
        index += "\n"

    for arch in arches:
        target = repo / "dists" / SUITE / COMPONENT / f"binary-{arch}"
        target.mkdir(parents=True, exist_ok=True)
        packages = target / "Packages"
        packages.write_text(index, encoding="utf-8")
        (target / "Packages.gz").write_bytes(gzip.compress(index.encode(), mtime=0))
        written[f"binary-{arch}/Packages"] = packages
        written[f"binary-{arch}/Packages.gz"] = target / "Packages.gz"
    return written


def build_release(repo: Path, arches: tuple[str, ...], version: str) -> Path:
    dists = repo / "dists" / SUITE
    dists.mkdir(parents=True, exist_ok=True)
    now = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())

    lines = [
        f"Origin: {REPO_LABEL}",
        f"Label: {REPO_LABEL}",
        f"Suite: {SUITE}",
        f"Codename: {SUITE}",
        f"Version: {version}",
        f"Architectures: {' '.join(arches)}",
        f"Components: {COMPONENT}",
        f"Description: Shinobi OS layer, laid over Kali. Installs alongside\n"
        f" kali-rolling; it does not replace it.",
        f"Date: {now}",
    ]

    # Every index that ships must be checksummed here, or apt refuses the
    # Release file as incomplete rather than guessing. The format wants one block
    # per hash type, each line being "hash size path" -- so they are collected
    # separately rather than filtered back out of a combined list.
    sha256_lines: list[str] = []
    md5_lines: list[str] = []
    for arch in arches:
        base = dists / COMPONENT / f"binary-{arch}"
        for name in ("Packages", "Packages.gz"):
            path = base / name
            if not path.is_file():
                continue
            data = path.read_bytes()
            sums = _checksums(data)
            rel = f"{COMPONENT}/binary-{arch}/{name}"
            size = len(data)
            sha256_lines.append(f" {sums['SHA256']} {size} {rel}")
            md5_lines.append(f" {sums['MD5sum']} {size} {rel}")

    if not sha256_lines:
        raise RepoError("no indexes were generated; refusing to write an empty Release")

    lines.append("SHA256:")
    lines.extend(sha256_lines)
    lines.append("MD5Sum:")
    lines.extend(md5_lines)

    release = dists / "Release"
    release.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return release


# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------


def sign(release: Path, key: str | None, gpg: str = "gpg") -> tuple[Path | None, Path | None]:
    """Produce InRelease and Release.gpg. Returns (inrelease, detached)."""
    if not key:
        return None, None
    for args, output in (
        ([gpg, "--batch", "--yes", "--local-user", key, "--clearsign",
          "--output", str(release.with_name("InRelease")), str(release)], "InRelease"),
        ([gpg, "--batch", "--yes", "--local-user", key, "--armor",
          "--detach-sign", "--output", str(release.with_name("Release.gpg")), str(release)], "Release.gpg"),
    ):
        proc = subprocess.run(args, capture_output=True, text=True)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout).strip().replace("\n", " ")[:400]
            raise RepoError(f"gpg failed to write {output}: {detail}")
    return release.with_name("InRelease"), release.with_name("Release.gpg")


# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="build-repo",
        description="Build a signed apt repository for the Shinobi layer.",
    )
    parser.add_argument("output", help="repository root to write")
    parser.add_argument("debs", nargs="+", type=Path, help=".deb files to publish")
    parser.add_argument(
        "--version", default=None,
        help="layer version stamped into Release (default: read from a .deb)",
    )
    parser.add_argument(
        "--key", default=os.environ.get("SHINOBI_REPO_KEY", ""),
        help="GPG key id to sign with; defaults to $SHINOBI_REPO_KEY",
    )
    parser.add_argument(
        "--gpg", default=os.environ.get("SHINOBI_GPG", "gpg"),
        help="gpg binary to use (defaults to $SHINOBI_GPG or 'gpg')",
    )
    parser.add_argument(
        "--allow-unsigned", action="store_true",
        help="build without signing; prints a warning rather than looking signed",
    )
    parser.add_argument(
        "--arch", action="append", default=None,
        help=f"architecture to publish (repeatable; default: {' '.join(ARCHITECTURES)})",
    )
    args = parser.parse_args(argv)

    debs = [d for d in args.debs if d.is_file()]
    missing = [str(d) for d in args.debs if not d.is_file()]
    if missing:
        print(f"build-repo: not a file: {', '.join(missing)}", file=sys.stderr)
        return 1
    if not debs:
        print("build-repo: nothing to publish", file=sys.stderr)
        return 1

    version = args.version
    if not version:
        version = control_fields(read_control(debs[0])).get("Version", "0")

    arches = tuple(args.arch) if args.arch else ARCHITECTURES

    repo = Path(args.output)
    try:
        build_indexes(repo, debs, arches)
        release = build_release(repo, arches, version)
        if args.key:
            sign(release, args.key, args.gpg)
            print(f"signed with {args.key}")
        elif args.allow_unsigned:
            # Loudly, on stderr: an unsigned repository added to a sources.list
            # looks exactly like a signed one until apt prompts.
            print(
                "WARNING: unsigned repository. Anyone who adds this to their\n"
                "sources.list will get an unsigned-package warning, and so should\n"
                "they -- but they need to be told why before they see it.",
                file=sys.stderr,
            )
        else:
            print(
                "build-repo: refusing to write an unsigned repository.\n"
                "  Pass --key <gpg-id>, or --allow-unsigned if you mean it.",
                file=sys.stderr,
            )
            return 1
    except RepoError as exc:
        print(f"build-repo: {exc}", file=sys.stderr)
        return 1

    print(f"{repo}/dists/{SUITE}/Release  (version {version}, arches {' '.join(arches)})")
    print("Add to a host with:")
    print(f"  deb [signed-by=/usr/share/keyrings/shinobi.gpg] http://shinobi-os.example/ {SUITE} {COMPONENT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())