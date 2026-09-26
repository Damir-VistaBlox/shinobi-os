#!/usr/bin/env bash
# Shinobi OS test suite.
#
#   ./tests/run-all.sh                    source-level tests only (fast, no ISO)
#   ./tests/run-all.sh path/to/shinobi.iso  source-level + ISO structure/content/boot
#
# The ISO argument used to be mandatory, which meant the fast source checks
# could not be run at all without a multi-gigabyte build artifact in hand --
# and CI ended up running a hand-picked subset instead of this script. The
# source-level tests are the ones that need no ISO and catch the most, so
# they run first and always.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${1:-}"
if [[ $# -gt 0 && ! -f "$ISO" ]]; then
  echo "run-all: not a file: $ISO" >&2
  exit 1
fi
cd "$ROOT"

SOURCE_TESTS=(
  tests/test-static.sh
  tests/test-control-plane.sh
  tests/test-control-paths.sh
  tests/test-approvals.sh
  tests/test-doctor.sh
  tests/test-hook.sh
  tests/test-launcher-env.sh
  tests/test-migrate.sh
  tests/test-build-config.sh
  tests/test-docs.sh
  tests/test-fonts-hook.sh
  tests/test-variant-parity.sh
  tests/test-webapp.sh
  tests/test-tool-process.sh
  tests/test-scope-gate.sh
  tests/test-http-headers.sh
  tests/test-mcp-layout.sh
  tests/test-mcp-e2e.sh
  tests/test-tool-registry.sh
  tests/test-source-integrity.sh
)

for test in "${SOURCE_TESTS[@]}"; do
  if [[ ! -x "$test" ]]; then
    # A non-executable test is an outage: it looks like it runs and does
    # nothing. This exact bug shipped once, when test-tool-process.sh was
    # committed with mode 100644 and the suite died at that step.
    echo "run-all: $test is not executable (mode $(stat -c '%a' "$test"))" >&2
    exit 1
  fi
  echo "--- $test"
  "./$test"
done

# Packaging validation needs dpkg-deb, so it only runs where Debian tooling
# exists. Everywhere else it is reported as skipped rather than silently
# absent, so a green run is never mistaken for a fully verified package.
if command -v dpkg-deb >/dev/null 2>&1; then
  echo "--- tests/test-package.sh"
  ./tests/test-package.sh
else
  echo "--- tests/test-package.sh: SKIPPED (dpkg-deb unavailable)"
fi

if [[ -z "$ISO" ]]; then
  echo
  echo "Shinobi OS source test suite: PASS"
  echo "(ISO structure, image content and BIOS/UEFI boot tests skipped; pass an ISO path to run them)"
  exit 0
fi

echo "--- tests/test-iso-structure.sh"
./tests/test-iso-structure.sh "$ISO"
echo "--- tests/test-image-content.sh"
./tests/test-image-content.sh "$ISO"
echo "--- tests/test-qemu-boot.sh (bios)"
./tests/test-qemu-boot.sh "$ISO" bios
echo "--- tests/test-qemu-boot.sh (uefi)"
./tests/test-qemu-boot.sh "$ISO" uefi

echo
echo "Shinobi OS automated test suite: PASS"
