#!/usr/bin/env bash
# Run the ISO's chroot hooks against a real Kali rootfs in a throwaway container,
# in minutes instead of after a multi-hour build.
#
# The ISO build is the only thing that runs distro/overlay/.../hooks/live/*.chroot,
# and it takes hours on a dedicated builder, so a hook that cannot work shows up
# as a build that dies in the chroot. This runs the same sequence (stage the
# sources as build.sh does, install the variant's package list, run the hooks in
# order) in a kali-rolling container and then checks the result against what
# tests/test-image-content.sh requires of the finished ISO. See
# distro/lib/dry-run-chroot.sh for what it can and cannot reproduce.
#
# Needs docker and a network (it installs a few hundred MB of Kali packages; they
# are cached in the named volume below, so a rerun does not fetch them again).
# Nothing in the checkout is written: it is mounted read-only.
#
#   distro/dry-run-hooks.sh [--variant NAME] [--continue]
#
#   SHINOBI_DRYRUN_IMAGE   the base image (default kalilinux/kali-rolling:latest)
#
# To drop the package cache:  docker volume rm shinobi-dryrun-apt
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
variant="${SHINOBI_VARIANT:-shinobi}"
continue_flag=""
while (($#)); do
  case "$1" in
    --variant) variant="${2:?--variant needs a name}"; shift 2 ;;
    --continue) continue_flag="--continue"; shift ;;
    -h | --help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "dry-run-hooks: unknown argument" >&2; exit 64 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "dry-run-hooks: docker is required" >&2
  exit 1
fi

exec docker run --rm \
  -v "$ROOT":/repo:ro \
  -v shinobi-dryrun-apt:/var/cache/apt/archives \
  "${SHINOBI_DRYRUN_IMAGE:-kalilinux/kali-rolling:latest}" \
  bash /repo/distro/lib/dry-run-chroot.sh "$variant" "$continue_flag"
