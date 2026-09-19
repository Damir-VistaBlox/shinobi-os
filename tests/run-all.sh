#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${1:?usage: $0 path/to/shinobi.iso}"
cd "$ROOT"

./tests/test-static.sh
./tests/test-control-plane.sh
./tests/test-source-integrity.sh
./tests/test-iso-structure.sh "$ISO"
./tests/test-image-content.sh "$ISO"
./tests/test-qemu-boot.sh "$ISO" bios
./tests/test-qemu-boot.sh "$ISO" uefi
echo "Shinobi OS automated test suite: PASS"
