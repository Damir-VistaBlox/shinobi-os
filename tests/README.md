# Shinobi OS local test suite

| `test-repo.sh` | The apt overlay repository: index layout apt requires, per-arch indexes, checksums that match the files, a reproducible index, real GPG signing verified with `gpg --verify`, refusal to publish unsigned without the explicit opt-out, refusal of a natively-compiled or malformed package rather than mirroring it, and the operator-facing `shinobi repo` command's keyring and pinning contract |

| `test-setup.sh` | The layer's engine, `shinobi-setup`, exercised in a real Kali chroot: refusing a system with no account to apply to, filling skel and the account's home, fixing ownership (the bug that made SDDM refuse logins), idempotence across repeated runs, an operator's local config surviving a re-apply unless `--force`, an account never being renamed unless asked by name, the sudoers rule that names the account being rewritten with it, and a missing desktop package failing loudly. Runs itself in a container when not root |

| `test-installer.sh` | The Shinobi Installation Wizard's configuration: the sequence is complete and correctly ordered, the two shellprocess jobs have separate configs, the install is offline, the live session's home and sudoers grant are excluded from the copy and its account is removed, no autologin can be inherited, the branding names Shinobi rather than Kali, and Calamares itself loads the configuration and reports no unusable module, no empty job and no broken QML (in a container, headless under Xvfb), and, run that way with the wizard's PATH, still applies its layout by running `setxkbmap` by name, which is the one thing the live session's layout follows |
| `test-installer-autostart.sh` | `shinobi-installer-autostart`, the one script between a boot-menu entry and the wizard: only a boot whose command line carries `shinobi.installer` (bare or `=1`, not a lookalike) starts it; it waits for Hyprland to answer on its IPC socket (it used to ask KWin, which this desktop does not have, so every boot waited 30 seconds and then claimed the desktop had not reported ready); after 30 seconds' worth of waiting it starts the wizard anyway; and with no calamares it fails at once with the reason. It also covers `shinobi-installer-run`: the wizard is started with a fixed system PATH with `installer-shims/` (the `setxkbmap` that makes a layout chosen on the keyboard page reach the live session) in front, set on the far side of `sudo`, which replaces PATH itself. Runs on a PATH of fakes so the real `hyprctl` of the machine running it is never consulted |

| `test-update.sh` | `shinobi update check`: a metadata refresh through `pkexec` runs once, and a failing or dismissed one is not run again through `sudo` (it used to be, with the second run's success reported as the result); without `pkexec` it is `sudo`, once; dry runs use neither; the live preview refuses with 78 before running anything; and the live-preview check names each medium path once. Runs on a PATH of recording fakes, so no real `apt-get`, `sudo` or `pkexec` is reachable |
| `test-keyboard.sh` | The keyboard layout chain, so that a password means the same thing at the wizard, the login screen, the session and the lock screen. `shinobi-keyboard` (what the Hyprland session is told, from the installer's choice, then `/etc/default/keyboard`, then `us`) with a fake `hyprctl` so no run can touch the compositor of whoever runs it: the file formats Calamares writes, values that must never reach a shell or a config file, a layout the wizard chose surviving a reload, a variant cleared when the operator goes from French azerty to German, and `repair` for the variant Calamares drops from the files it writes for a layout with `us` in front (checked against real xkbcommon: the files as written do not compile as a keymap). The wizard's `setxkbmap` stand-in with the argument shapes `Config.cpp` builds (`-variant ,`, a bare comma, `-query` and `-print` passed through), including acting as the session's account when it runs as root. And the end-to-end claim, with the real xkb library (`tests/xkb-decode.py`): a password typed on the layout the operator chose in the wizard is read as the same password by the login screen and by the session, for gb, de, fr, es, it, pt, nl, se, ru, ua, and is a *different* password on the `us` layout both used to have. `tests/calamares-keyboard.py` transcribes what Calamares 3.4.2 runs and writes for a choice, checked against a booted image. Needs `libxkbcommon0` and `xkb-data`, and fails without them rather than skipping |
| `test-branding.sh` | What the operator sees: a token sweep over boot menus, branding, session configs and desktop entries for `kali` appearing anywhere an operator would read it, with every allowance carrying a reason; the boot menu leading with Shinobi's installer and naming the live account; the installer marker set on exactly the entries that should carry it; and Calamares present on the image that installs but not on a package every CLI install would drag it into |
| `test-sddm-theme.sh` | The login screen: the SDDM theme ships every file the greeter reads, is a Qt 6 theme importing only core QtQuick (a theme needing an optional Qt module silently falls back to the base image's), never logs and always masks the password, and is selected by a drop-in that also turns off SDDM's on-screen keyboard (which covers the password field). With `qml6` it then renders every state of the real `Main.qml` offscreen against mock SDDM objects and checks the pixels (accent border, red on failure, Caps Lock notice, long passwords clipped, a usable form when settings or wallpaper are unreadable), and drives the keyboard layout chip against a mock shaped like SDDM's keyboard model (absent with one layout, relabelled when the layout changes, cycled and wrapped by a click, and a login after a switch going out under the new layout); `tests/sddm-theme-render.py` is the renderer |

| `test-install-e2e.sh` | Boots the image, installs it with the Shinobi Installation Wizard **driven like a person** (keys pressed through QEMU's monitor, translated for the layout under test with the real xkb library, so `SHINOBI_E2E_LAYOUT=de` presses the keys of a German keyboard), boots **what was installed** from its disk, logs in at the login screen with the password typed in the wizard, and asserts against it: the layout chosen on the wizard's page reaches the live Hyprland, the installed session is on the system's layout, one account and not the live session's, the layer present, the home owned by its account, no inherited autologin, the medium not in fstab, provenance readable, and the lock screen takes the same key presses. Needs an image (`SHINOBI_E2E_ISO`) and KVM and takes about 20 minutes, so it is **not** in `run-all.sh` and skips with an explanation rather than passing quietly |
| `test-vm-harness.sh` | The pieces that e2e drives a guest with, without a guest, and in `run-all.sh`: `tests/vm-drive.py`'s translation of text into the key presses of a layout (`zy` on `de` is the keys a US keyboard has Y and Z on, which is why a password typed on one layout is a different password on another; AltGr-only and untypeable characters are errors), its key and screenshot commands against a stand-in for QEMU's monitor, and `tests/vm-agent.py` with `tests/fixtures/guest-agent.sh` talking to each other, including the server refusing uploads outside `<session>/out.N`, oversized ones and paths that leave its directory |

| `test-installer-target.sh` | The wizard's own work, executed: a target shaped like an installed system (the three staged packages, the live session's account with no home behind it, its autologin, its stale apt lists, the medium in fstab) and the exact command vectors parsed out of the wizard's configuration run against it in a chroot. Asserts what the target looks like afterwards -- one account, the live one gone, an account with a home left alone, no autologin, the layer applied, provenance written, and the keyboard variant Calamares wrote one entry short put back in both files |

## The one suite not in `run-all.sh`

`test-install-e2e.sh` needs a built image and KVM, and takes about 25 minutes. It
is excluded because a suite that needs an artifact a CI run does not have would
be skipped on every push, and a permanently skipped suite is indistinguishable
from one that passes. It is run deliberately:

```sh
SHINOBI_E2E_ISO=~/shinobi-iso-dl/shinobi-os-amd64.iso ./tests/test-install-e2e.sh
```

Everything the source suite checks is about the tree being coherent. The three
claims that only an image can confirm -- that the live account is created as
`shinobi`, that the control plane starts (the `RuntimeDirectory` fix), and that
the wizard installs anything at all -- are checked here or nowhere.

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
| `test-providers.sh` | `providers/*.toml` is the LLM provider registry: every manifest classifies its `egress`, cloud endpoints are refused when they are not https or point at loopback, private, CGNAT or metadata addresses, a `local` provider must declare the peers that make it local, unknown fields and duplicate ids are refused, layers compose without silently shadowing, the credential broker round-trips keys at 0600 while refusing bad ids, empty keys, loose modes and planted symlinks, `shinobi provider readiness` names each of the four independent gates — stored key, engagement cloud clearance, operator-or-above trust profile, and per-engagement provider allowlist — and both market-standard wire shapes (`/chat/completions` and `/messages`) build and round-trip a tool call, so a shipped manifest is not merely one that parses |
| `test-provider-default.sh` | The default provider: a selection that waives nothing. User over system over packaged layering; a malformed, empty, symlinked, oversized or dangling value is an error and never falls through to a lower layer or to "whichever provider is ready"; `readiness` blocks every provider, local ones included, when there is no usable engagement, and honours a `llm.models` allowlist; a key piped in by a secret manager (which ends in a newline) is accepted while an embedded newline is still refused; setting a default and storing or forgetting a key leave an audit record and an event that carry no key; and `shinobi llm ask` with no provider uses the default, refuses without one, never asks a local provider for an approval, and still asks a cloud provider for one |
| `test-menu-provider.sh` | The LLM provider route of the wofi menu (`shinobi-menu provider`), driven with a fake wofi, kitty and notify-send over the real `shinobi-provider`. What wofi returns is typed text when nothing matches, so a choice is only acted on if it equals a row that was offered (typing `--clear`, an unlisted action, or shell syntax changes and runs nothing), the id that reaches argv comes from the readiness report and has to look like a provider id, the key is typed in a terminal started from an argument vector (never taken in the menu, never a string a shell parses), forgetting a key asks first (the safe answer is the first row, so a bare Enter keeps the key), a default of your own that cannot be used is explained and can be cleared, and what the commands say (the cloud notice, a refused change, a change that was made but could not be audited, an unreadable manifest) reaches the operator as a notification |
| `test-egress.sh` | The egress gate: an engagement with no `llm:` block cannot use a cloud provider, a misspelled or mistyped block denies rather than defaults, the scope file and engagement directory must be trustworthy, a `local` provider must still be reaching the peers it declared, cloud egress needs written clearance *and* an operator profile *and* a stored key *and* a single-use approval bound to this prompt's digest, provider and model, allowlists narrow but never widen and an empty list means none, and every refusal lands in both audit trails with the prompt itself nowhere in either |
| `test-llm.sh` | The native client, end to end against a real local HTTP provider and a real MCP subprocess: a tool call runs through `shinobi-recon` and its result goes back to the model, every turn is approved separately and bound to a different digest, a spent approval cannot be claimed twice, the connected socket is checked rather than the hostname, redirects are refused without the target being contacted, an https request is pinned to the vetted address while the certificate is verified against the name in the manifest with a verifying context actually supplied to the socket, an over-sized response is refused rather than buffered, a tool result carrying an image is described rather than forwarded, the tool server is resolved by preference order -- an installed entry point over a `bin/` script over the Python project in `mcp-servers/`, with names that are not package names refused rather than turned into an argv -- and the real `shinobi_recon` server is asked for its tools and its refusals, not only a fake that already agrees with the client; non-JSON tool arguments and a server that dies or lies are refused, an api key travels in the `Authorization` header and appears in no body, conversation, or audit record, the prompt is never in argv, and a local provider needs no approval while a cloud one does |
| `test-approvals.sh` | Approval lifecycle end to end: exact-argument binding, single use, atomic claim, expiry, and that scope is still checked first |
| `test-control-plane.sh` | The control plane over a real socket |
| `test-control-paths.sh` | Every command in the control plane resolves to a real implementation |
| `test-tool-process.sh` | Manifest-declared tool binaries actually run, and the ones that must stay in-process do |
| `test-launcher-env.sh` | `shinobi-agent` exports the engagement root the gate expects |
| `test-agent-egress.sh` | `shinobi-agent` wires the governed recon server into the agent and refuses to launch on ungoverned egress without an acknowledgement |
| `test-agent-setup.sh` | `shinobi agent install / login / setup / registry`: guide-only set-up of Claude Code and Codex. Runs against a PATH of a few linked system tools plus a fake `curl`, `claude` and `codex` (this machine very likely has the real ones, and a test must never reach them), answering the prompts through a pseudo-terminal (`tests/pty-drive.py`) because the command reads them from `/dev/tty`, not stdin. Nothing runs with no terminal, on a piped `yes`, on text typed or pasted before the question, on a no, an empty answer or end of input, for an id not in the table (which is not repeated back), or when the audit record that intent was about to be acted on cannot be written; the install and the login each have their own confirmation, shown after what will run; the session-wide acknowledgement never stands in for the confirmation; a failed download is a failed install (pipefail) and an installer that leaves no binary is not a success; the vendor's output stays on the terminal; Claude Code's login starts in an empty temporary directory; Codex's login state is the vendor's own answer; a file named like a standard module in the current directory is not imported by the wrapper; and the code (checked from its syntax tree, not by grepping for names) reads no file but the default-agent setting and checks no path but the documented ones |
| `test-migrate.sh` | The config-version stamp: a corrupt stamp migrates rather than silently skipping forever |
| `test-build-config.sh` | The squashfs settings are validated against live-build's list before becoming build config |
| `test-hooks-dryrun.sh` | Opt-in (`SHINOBI_DRYRUN=1`; needs docker and a network, ~2 min). Runs `distro/dry-run-hooks.sh`: stages the sources as `distro/build.sh` does, installs the variant's package list in a `kali-rolling` container, runs the ISO's `*.chroot` hooks in order (stopping at the first failure, as live-build does), then holds the result to the expectations in `tests/test-image-content.sh` (read from that file, so they cannot drift) plus the ones installing and logging in depend on. It found the hook that aborted on a chroot with no login account, the installer package that never reached the image, the Nerd Font that was never installed (the engine looked for its installer on PATH) and a stale copy of the installer package shipped inside itself. The preview build workflow sets it, so such failures arrive before a multi-hour build; if it is requested and docker is missing it says so loudly instead of passing quietly. Not a proof the ISO builds: it has no Kali hooks or common package lists, no kernel and no systemd, and omits Recommends unless given `--with-recommends` |
| `test-package-layout.sh` | The staged `.deb` tree, on any host: the recon server is shipped and importable from where it was put, its entry point and postinst check are executable and resolve *this* package's copy rather than one already on the machine, the declared dependencies cover what the shipped code actually imports, the postinst check passes with the dependency present and fails without it, and no bytecode residue ships |
| `test-wrapper-cwd.sh` | No command in `bin/` lets the directory it is run from decide what code it runs. `python3 -m`, `-c` and `python3 - <<script` put the current directory first on `sys.path`, ahead of `PYTHONPATH` and the standard library, so a `json.py` in a cloned repository or an extracted target would be imported in the process that holds approvals and keys. Statically, every such invocation in `bin/` must carry `-P` (so a new wrapper written the old way fails here); by behaviour, each read-only command is run from a directory full of planted lookalikes of standard modules and none may be imported, with a control proving the plants work without `-P`. Skips on Python older than 3.11 |
| `test-fonts-hook.sh` | Build hooks: the font download is checksum-verified before unpacking |
| `test-doctor.sh` | `shinobi-doctor` really checks what it claims, including setuid/setgid files |
| `test-hook.sh` | Hook install/run: event validation, secure roots, user-hook confirmation |
| `test-event-helper.sh` | `shinobi_emit_event` passes `shinobi-event` the payload it was given, with no stray brace, `{}` when there is none, and never fails its caller; and creating an engagement really publishes `engagement.created` through the real `shinobi-event` |
| `test-theme-set.sh` | `shinobi-theme set` finishes cleanly for every theme that ships: exits 0, says it worked, records the theme, repoints the Hyprland colours, and publishes `theme.changed` through the real `shinobi-event`; unknown and invalid names are still refused rather than crashing |
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

`test-keyboard.sh` needs the real xkb library (`libxkbcommon0` and `xkb-data`) and
*fails* without it, the opposite choice: its whole claim is that key presses read
through the layouts involved give the same password, and a run that quietly skipped
that would pass without having checked it. Both workflows install the two packages.

`test-package.sh` builds and inspects the real `.deb`, so it needs `dpkg-deb` and
therefore Debian-family tooling. That is the target platform rather than an
inconvenience: Kali is Debian-based and the hosted PR runners are Ubuntu, so it
runs wherever the result matters. On other hosts it reports `SKIPPED`.

`test-package-layout.sh` exists because of that gap. Everything
`test-package.sh` checks about *what goes in* the package needs no Debian
tooling at all — `build-deb.sh --stage` is file copying — so that is checked in
the source suite, on every host, and the archive is still checked where it can
be.

The image-level suites need `xorriso`, `qemu-system-x86_64`, UEFI firmware
(OVMF) and `systemd-analyze`.

`shellcheck` and `pytest` are not used. The suites are plain Bash and inline
Python so they run on a stock Kali box with no extra packages.

## QEMU checks are disposable

They use `-snapshot` and never write to the ISO. Serial output is kept under
`qemu-test-logs/` (suitable for CI artifacts). A boot that exits early fails; a
graphical-only guest with no serial console is recorded as a survival check
rather than misreported as a full in-guest health check.
