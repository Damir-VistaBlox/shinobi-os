# Shinobi OS local test suite

## Running it

The source checks need no ISO and no build:

```sh
./tests/run-all.sh
```

That is the fast path and the one CI runs. An ISO argument adds the image
checks on top:

```sh
./tests/run-all.sh distro/kali-live/images/kali-linux-rolling-live-shinobi-amd64.iso
```

The ISO argument used to be mandatory, which made the quick checks impossible to
run without a multi-gigabyte artifact in hand — and CI ended up running a
hand-picked subset of this script instead. Individual suites can also be run
directly, which is usually what you want while working on one of them.

## Suites

Every suite is standalone, prints `PASS`/`FAIL` with a count, and exits non-zero
on failure. `run-all.sh` runs them in this order and stops at the first failure.

### Source-level (no ISO required)

| Suite | What it covers |
| --- | --- |
| `test-static.sh` | Shell syntax, systemd unit syntax, overlay symlinks and permissions, service ownership, theme completeness |
| `test-source-integrity.sh` | Files the package ships are the files in the tree — no hand-maintained copies |
| `test-scope-gate.sh` | The engagement scope gate: authorized/refused targets, host resolution, engagement containment, date windows, durable audit records |
| `test-http-headers.sh` | Redirect re-authorization and bounded redirect chains |
| `test-mcp-layout.sh` | No module in the server package shadows a stdlib name, and the stdlib still resolves correctly with the package directory on `sys.path` |
| `test-mcp-e2e.sh` | The assembled `shinobi-recon` server driven over stdio by a real MCP client: all four tools served, in-scope allowed, out-of-scope refused, `nmap_scan` refused until a human approves that exact call, approval not replayable, and both outcomes audited. Skips when the `mcp` package is absent |
| `test-tool-registry.sh` | `tools/*.toml` is the single source of truth: every MCP tool has a manifest, values come from the manifest, the old hardcoded timeout constants stay gone |
| `test-providers.sh` | `providers/*.toml` is the LLM provider registry: every manifest classifies its `egress`, cloud endpoints are refused when they are not https or point at loopback, private, CGNAT or metadata addresses, a `local` provider must declare the peers that make it local, unknown fields and duplicate ids are refused, layers compose without silently shadowing, and the credential broker round-trips keys at 0600 while refusing bad ids, empty keys, loose modes and planted symlinks |
| `test-approvals.sh` | Approval lifecycle end to end: exact-argument binding, single use, atomic claim, expiry, and that scope is still checked first |
| `test-control-plane.sh` | The control plane over a real socket |
| `test-control-paths.sh` | Every command in the control plane resolves to a real implementation |
| `test-tool-process.sh` | Manifest-declared tool binaries actually run, and the ones that must stay in-process do |
| `test-launcher-env.sh` | `shinobi-agent` exports the engagement root the gate expects |
| `test-migrate.sh` | The config-version stamp: a corrupt stamp migrates rather than silently skipping forever |
| `test-build-config.sh` | The squashfs settings are validated against live-build's list before becoming build config |
| `test-fonts-hook.sh` | Build hooks: the font download is checksum-verified before unpacking |
| `test-doctor.sh` | `shinobi-doctor` really checks what it claims, including setuid/setgid files |
| `test-hook.sh` | Hook install/run: event validation, secure roots, user-hook confirmation |
| `test-webapp.sh` | The webapp record cannot choose the program or URL that runs, and `.desktop` `Exec=` cannot be used to inject flags |
| `test-variant-parity.sh` | Both variants install the same integration layer, and the console variant stays console-only |
| `test-package.sh` | The real `.deb`: control metadata, expected file list, executables still executable, no bytecode residue, and packaged manifests byte-identical to the source and still loading with policy intact |
| `test-docs.sh` | Documentation matches the tree: tool lists, suite lists, build knobs, command references, pinned actions |

### Image-level (require the ISO argument)

| Suite | What it covers |
| --- | --- |
| `test-iso-structure.sh` | El Torito metadata, boot files, embedded SquashFS, compression |
| `test-image-content.sh` | Extracts the live SquashFS and verifies the installed files, package policy and service ownership |
| `test-qemu-boot.sh` | Boots the image through BIOS and UEFI in a disposable QEMU snapshot |

## Requirements

Source-level suites need Bash and `python3`. `test-mcp-e2e.sh` needs the `mcp`
package and reports `SKIPPED` without it rather than failing, because a missing
client library is not a broken server.

`test-package.sh` builds and inspects the real `.deb`, so it needs `dpkg-deb` and
therefore Debian-family tooling. That is the target platform rather than an
inconvenience: Kali is Debian-based and the hosted PR runners are Ubuntu, so it
runs wherever the result matters. On other hosts it reports `SKIPPED`.

The image-level suites need `xorriso`, `qemu-system-x86_64`, UEFI firmware
(OVMF) and `systemd-analyze`.

`shellcheck` and `pytest` are not used. The suites are plain Bash and inline
Python so they run on a stock Kali box with no extra packages.

## QEMU checks are disposable

They use `-snapshot` and never write to the ISO. Serial output is kept under
`qemu-test-logs/` (suitable for CI artifacts). A boot that exits early fails; a
graphical-only guest with no serial console is recorded as a survival check
rather than misreported as a full in-guest health check.
