#!/usr/bin/env bash
# Tests the apt overlay repository builder.
#
# The overlay is the piece that makes Shinobi a layer rather than a fork: the
# AI tooling installs *alongside* kali-rolling, which is where the security
# fixes for the tools this project exists to expose actually arrive. A stale
# fork stays perfectly installable, so the layering is the security property and
# the repository is how it is expressed.
#
# These build .deb files by hand, as ar archives, rather than shelling out to
# dpkg-deb. That is not a shortcut: dpkg-deb does not exist on the machines most
# likely to run this test, and a repo builder you cannot test off the ISO builder
# is a repo builder you only test in one place. It also means the test asserts on
# the bytes the builder actually reads.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

failures=0
checks=0
check() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

builder="$ROOT/packaging/build-repo.py"
export PYTHONPATH="$ROOT/libexec/shinobi"

# A minimal but structurally real .deb: ar archive, gzipped control.tar holding
# ./control, and a data.tar. dpkg-deb is not consulted anywhere.
make_deb() {
  local out="$1" package="$2" version="$3" arch="${4:-all}" extra="${5:-}"
  python3 - "$out" "$package" "$version" "$arch" "$extra" <<'PY'
import gzip, io, sys, tarfile

out, package, version, arch, extra = sys.argv[1:6]

control = f"""Package: {package}
Version: {version}
Maintainer: Shinobi OS Maintainers <maintainers@shinobi-os.local>
Architecture: {arch}
Depends: python3, bash
Section: x11
Priority: optional
Description: a package for testing
 A short summary line.
 .
 {extra}
"""

def tar_gz(name, text):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo(name)
        data = text.encode()
        info.size = len(data)
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()

def ar_member(name, payload):
    header = (
        f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(payload):<10}`\n"
    ).encode()
    return header + payload + (b"\n" if len(payload) % 2 else b"")

blob = (
    b"!<arch>\n"
    + ar_member("debian-binary", b"2.0\n")
    + ar_member("control.tar.gz", tar_gz("./control", control))
    + ar_member("data.tar.gz", tar_gz("./usr/bin/thing", "#!/bin/sh\n"))
)
open(out, "wb").write(blob)
PY
}

echo "== the builder refuses to publish anything unsigned =="
make_deb "$work/a.deb" shinobi-core 0.1.0
if python3 "$builder" "$work/repo1" "$work/a.deb" >/dev/null 2>"$work/err1"; then
  check "unsigned is refused" "refused" "published"
else
  check "unsigned is refused" "refused" "refused"
  check "and says how to sign it" "$(grep -c -- '--key' "$work/err1" || true)" "1"
  check "and offers the explicit opt-out" "$(grep -c -- 'allow-unsigned' "$work/err1" || true)" "1"
fi

echo "== a built repository has the shape apt requires =="
python3 "$builder" --allow-unsigned "$work/repo" "$work/a.deb" >/dev/null 2>"$work/err2"
for path in \
  dists/kali-shinobi/Release \
  dists/kali-shinobi/main/binary-all/Packages \
  dists/kali-shinobi/main/binary-all/Packages.gz \
  pool/main/a.deb
do
  check "$path exists" "$([[ -f $work/repo/$path ]] && echo yes || echo no)" "yes"
done
# binary-all alone is where an Architecture: all package belongs, but the pinned
# and older tooling in the field asks for binary-amd64 and finds nothing there.
for arch in all amd64 arm64; do
  check "binary-$arch is published" \
    "$([[ -f $work/repo/dists/kali-shinobi/main/binary-$arch/Packages ]] && echo yes || echo no)" "yes"
done
# An unsigned build must say so on stderr: a repository that looks signed is the
# failure mode this exists to prevent.
check "an unsigned build warns on stderr" \
  "$(grep -c 'WARNING: unsigned' "$work/err2" || true)" "1"

echo "== the index describes the package accurately =="
index="$work/repo/dists/kali-shinobi/main/binary-all/Packages"
check "Package is the package name" "$(sed -n 's/^Package: //p' "$index")" "shinobi-core"
check "Version is carried through" "$(sed -n 's/^Version: //p' "$index")" "0.1.0"
check "Depends survives" "$(sed -n 's/^Depends: //p' "$index")" "python3, bash"
check "Filename points into the pool" "$(sed -n 's/^Filename: //p' "$index")" "pool/main/a.deb"
check "Size matches the file on disk" \
  "$(sed -n 's/^Size: //p' "$index")" "$(stat -c %s "$work/repo/pool/main/a.deb")"
check "the SHA256 in the index is the file's SHA256" \
  "$(sed -n 's/^SHA256: //p' "$index")" "$(sha256sum "$work/repo/pool/main/a.deb" | cut -d' ' -f1)"
# Description is the one field whose continuation lines are paragraphs, and
# flattening it produces an index that reads as one wall of text.
check "Description keeps its line structure" \
  "$(grep -c '^ A short summary line\.$' "$index" || true)" "1"
check "Description is emitted exactly once" \
  "$(grep -c '^Description: ' "$index" || true)" "1"
# Two builds of the same input must produce byte-identical indexes, or every
# diff between them looks like a real change.
python3 "$builder" --allow-unsigned "$work/repo-b" "$work/a.deb" >/dev/null 2>&1
check "the index is reproducible" \
  "$(cmp -s "$index" "$work/repo-b/dists/kali-shinobi/main/binary-all/Packages" && echo same || echo differs)" "same"

echo "== the Release file is complete =="
release="$work/repo/dists/kali-shinobi/Release"
check "Suite" "$(sed -n 's/^Suite: //p' "$release")" "kali-shinobi"
check "Codename" "$(sed -n 's/^Codename: //p' "$release")" "kali-shinobi"
check "Components" "$(sed -n 's/^Components: //p' "$release")" "main"
check "Architectures" "$(sed -n 's/^Architectures: //p' "$release")" "all amd64 arm64"
check "it states it does not replace Kali" \
  "$(grep -c 'does not replace it' "$release" || true)" "1"
# Every published index must be checksummed, or apt refuses the Release as
# incomplete rather than guessing which file it is missing.
for arch in all amd64 arm64; do
  check "binary-$arch/Packages is checksummed" \
    "$(grep -c "main/binary-$arch/Packages$" "$release" || true)" "2"
  check "binary-$arch/Packages.gz is checksummed" \
    "$(grep -c "main/binary-$arch/Packages.gz$" "$release" || true)" "2"
done
# The recorded hash must be the real one.
recorded="$(grep "main/binary-all/Packages$" "$release" | awk '{print $1}' | head -1)"
check "the recorded SHA256 is the index's" \
  "$recorded" "$(sha256sum "$work/repo/dists/kali-shinobi/main/binary-all/Packages" | cut -d' ' -f1)"

echo "== signing is real, and verifiable =="
if command -v gpg >/dev/null 2>&1; then
  export GNUPGHOME="$work/gnupg"
  rm -rf "$GNUPGHOME"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  if gpg --batch --quiet --passphrase '' --quick-generate-key \
       'Shinobi Repo Test <test@shinobi-os.local>' default default never >/dev/null 2>&1; then
    keyid="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')"
    if python3 "$builder" --key "$keyid" "$work/repo-signed" "$work/a.deb" >/dev/null 2>&1; then
      check "InRelease is produced" \
        "$([[ -f $work/repo-signed/dists/kali-shinobi/InRelease ]] && echo yes || echo no)" "yes"
      check "Release.gpg is produced" \
        "$([[ -f $work/repo-signed/dists/kali-shinobi/Release.gpg ]] && echo yes || echo no)" "yes"
      gpg --verify "$work/repo-signed/dists/kali-shinobi/Release.gpg" \
        "$work/repo-signed/dists/kali-shinobi/Release" >/dev/null 2>&1
      check "the detached signature verifies" "$?" "0"
      gpg --verify "$work/repo-signed/dists/kali-shinobi/InRelease" >/dev/null 2>&1
      check "the inline signature verifies" "$?" "0"
    else
      check "a signed build succeeds" "signed" "failed"
    fi
  else
    check "gpg could generate a throwaway key" "key" "no key"
  fi
  unset GNUPGHOME
else
  printf '  skip gpg unavailable; signing not exercised\n'
fi

echo "== a natively-compiled package is refused, not mirrored =="
# An amd64 .deb offered in an arm64 index installs, and then fails to run. The
# index is where that mistake is cheapest to prevent.
make_deb "$work/native.deb" shinobi-native 0.1.0 amd64
if python3 "$builder" --allow-unsigned "$work/repo-native" "$work/native.deb" >/dev/null 2>&1; then
  check "an Architecture: amd64 package is refused" "refused" "published"
else
  check "an Architecture: amd64 package is refused" "refused" "refused"
fi

echo "== a truncated or non-deb input is refused, not silently skipped =="
head -c 40 "$work/a.deb" >"$work/broken.deb"
if python3 "$builder" --allow-unsigned "$work/repo-broken" "$work/broken.deb" >/dev/null 2>&1; then
  check "a truncated .deb is refused" "refused" "published"
else
  check "a truncated .deb is refused" "refused" "refused"
fi
printf 'not a deb at all\n' >"$work/notadeb.deb"
if python3 "$builder" --allow-unsigned "$work/repo-notadeb" "$work/notadeb.deb" >/dev/null 2>&1; then
  check "a file that is not a .deb is refused" "refused" "published"
else
  check "a file that is not a .deb is refused" "refused" "refused"
fi
if python3 "$builder" --allow-unsigned "$work/repo-missing" "$work/nope.deb" >/dev/null 2>&1; then
  check "a missing file is refused" "refused" "published"
else
  check "a missing file is refused" "refused" "refused"
fi

echo "== the operator-facing command is wired to the repository =="
repo_cmd="$ROOT/bin/shinobi-repo"
check "shinobi-repo exists" "$([[ -x $repo_cmd ]] && echo yes || echo no)" "yes"
bash -n "$repo_cmd" 2>/dev/null
check "shinobi-repo is valid bash" "$?" "0"
# The key must be shipped, not fetched: a key retrieved over the channel that
# distributes the packages it authenticates proves nothing.
check "it uses a shipped keyring path, not one it fetches" \
  "$(grep -q 'keyring=/usr/share/keyrings/shinobi-archive-keyring.gpg' "$repo_cmd" && echo yes || echo no)" "yes"
check "and never downloads a key over the network" \
  "$(grep -qE '(curl|wget).*key(gpg)?\.(asc|gpg)' "$repo_cmd" && echo fetches || echo no)" "no"
check "it pins the origin so a name collision cannot silently win" \
  "$(grep -c 'Pin-Priority' "$repo_cmd" || true)" "1"
check "enable with no URL refuses" \
  "$(SHINOBI_REPO_URL= bash "$repo_cmd" enable >/dev/null 2>&1; echo $?)" "2"
check "status works with nothing enabled" \
  "$(bash "$repo_cmd" status >/dev/null 2>&1; echo $?)" "0"

echo
if ((failures > 0)); then
  printf 'repo-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\nrepo-test: PASS\n' "$checks" "$checks"