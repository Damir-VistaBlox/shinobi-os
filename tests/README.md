# Shinobi OS local test suite

Run the fast source checks from the repository root:

```sh
./tests/test-static.sh
```

Run the complete suite against a built ISO:

```sh
./tests/run-all.sh distro/kali-live/images/kali-linux-rolling-live-shinobi-amd64.iso
```

The suite checks package-profile policy, shell syntax, systemd unit syntax,
ISO El Torito metadata and boot files, then boots the image through both BIOS
and UEFI in a disposable QEMU snapshot. QEMU boot logs are written to
`qemu-test-logs/` (the directory is intentionally suitable for CI artifacts).

Host requirements for the full suite are `xorriso`, `qemu-system-x86_64`,
UEFI firmware (OVMF), and `systemd-analyze`. The static suite only requires
Bash; image-only executable checks are deferred until the package is installed
inside the image.
