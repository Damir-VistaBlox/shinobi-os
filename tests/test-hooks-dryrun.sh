#!/usr/bin/env bash
# Runs distro/dry-run-hooks.sh: the ISO's chroot hooks against a real Kali rootfs in
# a container, then the same expectations the finished ISO is held to.
#
# Opt-in, because it needs docker and a network and takes a couple of minutes
# (it installs a few hundred MB of Kali packages): SHINOBI_DRYRUN=1. The preview
# build workflow sets it, so a hook that cannot work fails before the multi-hour
# ISO build and not in the middle of it. Without docker it skips rather than fail.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${SHINOBI_DRYRUN:-}" != 1 ]]; then
  echo "hooks-dryrun-test: SKIP (set SHINOBI_DRYRUN=1; it needs docker, a network and about two minutes)"
  exit 0
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "hooks-dryrun-test: SKIP (docker is not available here)"
  exit 0
fi

exec "$ROOT/distro/dry-run-hooks.sh"
