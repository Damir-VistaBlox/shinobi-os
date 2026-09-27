# Shinobi OS — design notes

## The idea

Omarchy bolts AI agents onto an Arch/Hyprland desktop: a default-agent concept
(`omarchy-default-agent`), a launcher (`omarchy-agent`), per-agent installers
(`omarchy-install-ai-*`), and menu entries — all thin bash wrappers around
pacman/AUR packages and Hyprland IPC.

Kali isn't a general-purpose desktop; its reason to exist is ~600 security
tools. Porting Omarchy's *shell scaffolding* (bash launcher + menu + installer
scripts) is easy and low-value. The actual hard, valuable problem is porting
the *concept*: give an AI agent first-class, safe access to the thing the
distro is for. For Kali that means tool access, not theme switching — and
"safe" is load-bearing, because the tools this distro ships are the same ones
that get people arrested when pointed at the wrong host.

## Two layers

1. **Desktop layer** (`bin/shinobi`) — an Omarchy-style CLI: launch the AI
   agent in the right working directory, manage "engagements" (scope +
   logs), stay thin and boring. This is the easy 20%.
2. **Tool-access layer** (`mcp-servers/*`) — MCP servers that expose Kali
   tools to the agent as scope-checked, logged tool calls instead of raw
   shell access. This is the part worth building carefully.

## Scope-gating is the core mechanic

Every MCP tool call that touches a target must be checked against an
*engagement scope file* (`engagements/<name>/scope.yaml`: authorized
hosts/CIDRs, a client name, a time window) before it runs. Out-of-scope
targets are refused, not warned about. Every call — allowed or refused — is
appended to an engagement log (`engagements/<name>/log.jsonl`) with
timestamp, tool, args, target, and verdict. This is what makes "AI runs nmap
for you" defensible instead of reckless: authorization is enforced in code,
not left to the model's judgment or a prompt in CLAUDE.md.

Scope is necessary but not sufficient, which is the part that needed a second
mechanic. An in-scope target still does not authorize a tool that is
`live_mode` in its manifest: `nmap_scan` is refused and a human has to approve
that specific call with `shinobi approval approve` before it runs. The approval
is bound to the exact arguments, is single-use, and expires. Scope is checked
first, so an out-of-scope target is refused without an approval ever being
created. Both halves matter — scope says *which* targets, the approval says
*whether this particular active probe* — and neither is a substitute for the
other.

No tool in this repo shells out to an arbitrary command string from the
model. Each MCP tool takes structured parameters (target, a closed set of
flags) and builds the argv itself — never string-interpolates model output
into a shell.

## Egress-gating is the third mechanic

Scope and approval both decide whether a *probe* may run. Neither decides
whether the *question* may leave the machine, and that is a separate decision
with a separate set of ways to get it wrong. A prompt is client-confidential —
it is the part of an engagement that describes the target — so `shinobi llm`
sends it through a gate (`shinobi_control/egress.py`) that treats the network
as hostile:

- **A provider is a manifest, not a URL.** `providers/*.toml` declares the
  endpoint, the API dialect, the model list, whether egress is `local` or
  `cloud`, and the peers that make it local. A `local` provider must name
  `reachable_on`; that field is what makes the waiver mean something. Unknown
  manifest fields are refused rather than ignored, because a misspelled
  `cloud = true` that silently reads as local is the failure this project
  exists to prevent.
- **The prompt is never in argv.** It is read from stdin or a file, because
  argv is world-readable through `/proc` and lands in shell history. What
  crosses the wire instead is a digest of the request — canonical versioned
  JSON, hashed — so an approval can be bound to *this exact question* without
  the text being stored anywhere.
- **Every turn is its own approval.** A tool result changes the next request,
  so a conversation cannot ride on one approval: turn two is a different digest
  and needs a new grant, bound to digest, provider and model, expiring and
  single-use. Reusing turn one's approval would be approving a request nobody
  read. A `local` provider needs no approval at all, which is also why the
  loop's approval step has to be tested where it actually runs.
- **The address that answers is the address that was checked.** Names are
  resolved per request, every resolved address must be permitted, the socket is
  pinned to a vetted address, and then the connected peer is read back off the
  socket and compared. That last step is not redundant: a rebind exists
  precisely because the answer to a DNS query and the address a connection
  reaches need not be the same one.
- **TLS is verified against the name, not the address.** Pinning the socket to
  an address literal while verifying the certificate against that literal would
  fail every legitimate provider, since certificates are issued for names. So
  the name decides *who* is being talked to and the vetted address decides
  *where the bytes go* — and the verifying context is passed explicitly rather
  than left to whatever the stdlib defaults to, because a client that weakens
  certificate checking to reach one provider has weakened it for the key.
- **Redirects are refused.** Following one would send the prompt and the API
  key to a host that was never resolved, checked, or approved.
- **The API key goes in the `Authorization` header and reaches nothing else** —
  not the body, not the conversation, not the audit trail. A key in a log
  outlives the rotation that was supposed to remove it.
- **Nothing is persisted.** No transcript, no prompt, no tool output. There is
  nothing to leak later because there is no later copy.
- **Tools still run through the recon server**, as a subprocess speaking MCP.
  The client is not a second source of scope policy: it offers the server's
  tools to the model and the server remains the authority on scope, on
  approval, and on its own argument names. It deliberately does not
  re-validate tool arguments, because two copies of a schema drift and the laxer
  one wins.

Refusals land in both audit trails — the engagement log and the control-plane
journal — carrying the digest and a call id so a specific send can be
correlated, and never the prompt.

## MVP built now

- `bin/shinobi` — subcommands: `engagement new/list/use`, `scope show`,
  `agent` (launches the configured agent with the current engagement's
  MCP config wired in).
- `mcp-servers/shinobi-recon` — Python MCP server. `nmap_scan` was the proof of
  concept for the scope-gate + audit-log pattern; `dns_lookup`,
  `whatweb_scan` and `http_headers` followed it, and each is a thin function
  calling the same `require_in_scope()` + `log_call()` helpers. The next tool
  (gobuster, nikto...) is meant to be mechanical too, with one addition: a
  manifest in `tools/` is now required, because each tool's policy — binary,
  timeout, risk, scope and approval requirements — is read from there at import
  rather than restated as constants. A tool with no valid manifest stops the
  server from starting rather than being served ungoverned. See
  `mcp-servers/shinobi-recon/README.md` for the procedure.
- `bin/shinobi-llm` + `libexec/shinobi/shinobi_control/llm/` — the governed
  client itself. `shinobi llm ask <provider>` runs a conversation through the
  egress gate and offers the recon server's tools to the model; `shinobi llm
  check <provider>` describes a provider and what it would take to use it
  without sending anything. `bin/shinobi-egress` exposes the same decisions on
  their own (`check`, `show`, `trail`) for inspecting them.
- `providers/*.toml` + `shinobi_control/providerctl.py` — the provider
  registry and its credential broker, layered so a site can narrow what the
  shipped manifests allow without editing them.
- `install.sh` — apt + pipx provisioning for a fresh Kali box.

## Custom ISO (`distro/`)

The project grew a second layer: instead of `install.sh`-ing onto an existing
Kali install, build a full custom Kali live ISO with a Hyprland desktop and
shinobi preinstalled — closer to what Omarchy actually is (a whole opinionated
image), not just a package you add afterward.

This is built on Kali's own official build tooling
(`gitlab.com/kalilinux/build-scripts/kali-live`, vendored as a submodule),
not a from-scratch respin — Kali's `live-build` config already supports
adding a new "variant" (package list + hooks), which is exactly the
mechanism `distro/` uses. See [`distro/README.md`](./distro/README.md) for
the full layout and build instructions.

The desktop itself is a lean, self-contained Hyprland config in the spirit
of Omarchy (bar, launcher, sane keybindings, `SUPER+SHIFT+CTRL+A` → the
agent) — not a literal port of Omarchy's dotfiles, since those call
Omarchy-specific helper binaries that don't exist on Kali/Debian. The Quickshell
config also surfaces the active engagement name directly in the bar, reading
the same state file `shinobi engagement use` writes — so it's always visible
which `scope.yaml` is currently gating tool calls.

### Staged build-out, not one big untested build

`distro/` has two variants, picked via `SHINOBI_VARIANT`:

- **`shinobi-min`** — console only, no desktop at all. Just
  `kali-linux-core` + `kali-linux-default` + the shinobi tooling hook. Build
  this first: it isolates "does the shinobi CLI + shinobi-recon MCP server
  bake correctly into a real Kali chroot" from every desktop-specific risk
  (Hyprland/Quickshell/wofi package availability, a font fetched from GitHub at
  build time, SDDM theme detection) — and a GUI was never required for
  Shinobi OS's actual point (safe, scope-gated tool access), so this variant is
  arguably a legitimate end state on its own, not just a stepping stone.
- **`shinobi`** — the full Hyprland desktop, built once `shinobi-min` is
  confirmed working.

This ordering paid off immediately: the first real `shinobi-min` build (in a
QEMU/KVM VM, Kali's own pre-built QEMU image as the build host) succeeded on
the first attempt, but booting the resulting ISO surfaced a real bug —
`pyproject.toml` declared `mcp>=1.2.0` with no upper bound, so pip installed
`mcp` 2.x, which renamed `FastMCP` to `MCPServer` and broke `shinobi-recon` at
import time. Fixed by pinning `mcp>=1.2.0,<2`. Verified end-to-end on the
booted image afterward: `shinobi help` lists all commands correctly, an
in-scope `nmap_scan` is authorized and logged, an out-of-scope
target is refused *before* nmap runs and logs `"verdict": "refused"` — the
core safety mechanism this whole project exists for, confirmed working on a
real built-and-booted system, not just the earlier host-side unit tests.
Also confirmed on that same real system: the symlink-safety fix from the CLI
dispatcher work resolves the engagements directory correctly to
`~/.local/share/shinobi/engagements/` on an installed (non-checkout) system,
exactly as designed.

**Update**: `shinobi` (the full desktop) has now been built and verified too —
succeeded on the first build attempt with zero package or hook errors
(Hyprland/Quickshell/wofi/SDDM/hyprlock/hypridle, the GitHub-fetched Nerd Font,
the dotfiles hook, all confirmed present via a mounted-squashfs inspection;
the `mcp<2` fix carried over correctly). The SDDM login-theme hook correctly
took its fail-open path (logged "no SDDM Current= theme configured" instead
of guessing) — expected, not a bug.

The only real friction was infrastructure, not the build itself: the build
VM's host (a loaded daily-driver desktop, other work running concurrently)
didn't have reliable headroom for a 4GB VM, and the QEMU process was OOM-
killed twice before dropping to a 3GB headless VM (no GTK window — SSH only,
once key auth was set up) resolved it. Worth remembering if this needs
rebuilding on a similarly-loaded machine.

Not yet done: actually *booting* `shinobi` into a live Hyprland session
(needs a GUI, unlike the squashfs-mount verification above) to confirm SDDM
comes up, Hyprland starts, Quickshell renders with the Nerd Font, and the
keybindings work.

## Omarchy subsystem inventory

Omarchy is ~15 distinct subsystems, not just "Hyprland + an agent" —
`omarchy-*` on an Omarchy box lists ~250 commands. Each was triaged: port
as-is, port scoped-down, or skip as Arch-specific/irrelevant to a security
distro. Ported so far, all under `bin/shinobi-*`:

- **Unified CLI dispatcher** (`bin/shinobi`) — ported from `/usr/bin/omarchy`
  (~1100 lines, ~250 commands across ~80 groups, in the actual Omarchy
  install this repo was designed alongside). Same mechanism, scoped to our
  size: every `shinobi-*` script is auto-discovered, its route derived from
  its filename (`shinobi-hypr-toggle` → `shinobi hypr toggle`), and documented
  by parsing its own leading comments (`# shinobi:summary=`, `:args=`,
  `:examples=`, `:hidden=` — same convention as Omarchy's
  `# omarchy:summary=` etc.) instead of a hardcoded command table. `shinobi
  help` and `shinobi <cmd> --help` are generated from that, not maintained by
  hand. Left out of the port: `--json` output, the alias system, requires-
  sudo tracking, metadata-error validation — Omarchy needs those at 250
  commands; at a dozen, longest-prefix routing plus a generated listing is
  the whole job. Every leaf script stays independently callable too (exactly
  like Omarchy's own binaries) — hyprland.conf's keybindings call
  `shinobi-agent`/`shinobi-menu` directly, skipping the routing hop, same as
  Omarchy's bindings call `omarchy-agent` rather than `omarchy agent`.

  This port surfaced a real bug, fixed as part of it: `bin/shinobi`'s
  `dirname "${BASH_SOURCE[0]}"` self-location broke whenever the script was
  reached through a symlink on `$PATH` — exactly how `install.sh` and the
  ISO both install every `shinobi-*` command — because `BASH_SOURCE` holds
  the symlink's own path, not its target, without `readlink -f` first.
  `bin/_shinobi-common.sh` (shared helpers, not itself a command — hence the
  underscore, to stay out of every `bin/shinobi*` glob) fixes this once for
  all the leaf scripts, and changes what "the engagements directory" means:
  it's the checkout's `engagements/` when one is running from a git
  checkout (a resolvable sibling directory), and
  `${XDG_DATA_HOME:-~/.local/share}/shinobi/engagements` otherwise (the ISO,
  which copies `bin/` into `/opt/shinobi` without `engagements/`). Verified
  end-to-end against a symlink-only install with no checkout directly on
  `$PATH`, matching exactly how the ISO's build hook installs these.

- **Agent framework** (`shinobi-default-agent`, `shinobi agent --pick`,
  `shinobi agent prompt`) — ported from `omarchy-default-agent` /
  `omarchy-agent`. Scoped down: no `mise`-based auto-installer (checks PATH,
  prints an install hint instead), and Omarchy's ~300-line usage-tracking
  script (parses Claude Code transcripts *and* probes an undocumented
  Anthropic OAuth usage endpoint) was **not** ported — that's Omarchy's own
  dashboard integration against internal APIs, not something to
  speculatively re-implement.
- **Menu system** (`shinobi-menu`) — ported from `omarchy-menu`, scoped down:
  Omarchy's menu is a route in a persistent shell-IPC daemon
  (toggle/summon/close against `omarchy-shell`); we don't have that daemon,
  so this is a stateless wofi dmenu script that re-execs itself with a route
  argument for submenus. Same UX for the common case, no daemon to run.
- **Theme system** (`shinobi-theme`, `themes/kali-dark`, `themes/matrix`) —
  ported from `omarchy-theme-set-*`, scoped way down to the four apps this
  repo actually configures (hypr/Quickshell/wofi/kitty), not Omarchy's full
  per-app catalog (browser, GNOME, VSCode, keyboard RGB, ...). Mechanism:
  each app sources a fixed-path `colors.{conf,css}` file that `shinobi-theme
  set` repoints via symlink.
- **Capture + power** (`shinobi-capture`, `shinobi-power`) — ported from
  `omarchy-capture-*` / `omarchy-system-*`, with one Shinobi OS-specific twist:
  screenshots save into the *active engagement's* `evidence/` dir instead of
  `~/Pictures` — a screenshot taken mid-engagement is evidence, so it goes
  straight into the same audit trail `shinobi-recon` logs to.
- **Audio/network/bluetooth OSD** (`shinobi-audio`, `shinobi-network`,
  `shinobi-bluetooth`) — ported from `omarchy-audio-*` / `omarchy-network-*` /
  `omarchy-bluetooth-*` / `omarchy-osd`. Plain `pactl`/`nmcli`/`bluetoothctl`
  wrappers with `notify-send` popups instead of Omarchy's custom OSD widget
  (no equivalent daemon here) — wired into Quickshell (click) and media
  keys (`bindl`, so they work on the lock screen too).
- **Window management extras** (`shinobi-hypr-toggle`) — ported from
  `omarchy-hyprland-window-*` / `-toggle-*`. Fullscreen/center/pin use
  Hyprland's built-in dispatchers directly; only gaps and opacity need
  remembered state, so those are the only two that got a wrapper script.
- **Fonts** — a Nerd Font (JetBrainsMono, pinned to a verified-resolvable
  upstream release URL) installed by a build hook, since Debian/Kali's
  `fonts-jetbrains-mono` package is the *unpatched* font with no icon glyphs
  — Quickshell/wofi icons were silently relying on a font that was never
  actually installed until this.
- **Login theming** — Kali's active Breeze SDDM theme was verified in a real
  graphical live boot: its `theme.conf.user` `background=` setting accepts an
  image path. The image hook now replaces that setting with the Shinobi
  wallpaper; the next full-image build will validate the rendered override.
  Plymouth boot-splash theming remains unattempted: it is
  script-based, higher effort, and still needs separate live-boot validation.

See the categorized table from the design discussion (agent framework, menu,
webapp handler, voxtype = high value; theme, capture, notification/audio/
power = medium, worth adapting; package-mgmt wrapper, update/snapshot system,
hardware-quirks layer, consumer app installers, plugin system, dev tooling,
boot theming = low value / Arch-specific, skipped) for the full triage —
not reproduced here since it doesn't change often enough to duplicate.

## Deliberately not built yet (needs a decision, not more code)

- **Webapp handler** (`omarchy-webapp-install`) — wraps a local web UI as a
  native launcher app. Not ported yet; would matter if an MCP server grows a
  control UI, or for wrapping a tool's web UI (BloodHound, etc.) the same way.
- **Voxtype** (voice typing) — genuinely useful for dictating engagement
  notes; low priority, not started.
- **Update/versioning/snapshot system** — Omarchy's `omarchy-update-*` +
  `omarchy-snapshot` solves "keep a rolling install in sync with upstream."
  Only matters if Shinobi OS becomes an installed rolling distro rather than a
  one-shot ISO — that's an open decision, not just unbuilt code.
- **External agent CLIs are not behind the egress gate.** `shinobi agent`
  launches `claude`/`codex` with this engagement's MCP config wired in, so the
  *tools* are scope-gated, but the agent's own model traffic uses whatever
  authentication and endpoint that CLI was configured with. The native client
  exists partly to close this, and closing it properly means intercepting or
  replacing a third-party binary's transport — a decision, not a patch.
- **The `.deb` does not carry the recon server. It should; the dependency is
  available and the decision is made.** Today the image hook pip-installs it
  into `/opt/shinobi/venv`, so a real image and a
  checkout have tools while a bare `shinobi-core` install has none — and says
  so, pointing at `--server ''` rather than quietly running a toolless
  conversation. The blocker was never willingness but the dependency: apt
  cannot express a Python version bound.

  It is unblocked. Kali rolling ships `python3-mcp` at 1.26.0, which is the
  major version this server imports (`mcp.server.fastmcp`), so the package can
  depend on it instead of vendoring a pip install at install time. Two things
  to keep in view when landing it: Kali is rolling, and when `python3-mcp`
  reaches 2.x — where `fastmcp` no longer exists — every `shinobi-recon` will
  fail to import. That failure is loud and fail-closed, never a silent
  ungoverned server, but the postinst should verify the import rather than let
  an unusable package look installed. And installing a Python package into
  Debian properly wants `dh_python3`, which is not available on the machine
  this decision was made on, so the layout is a question for a Debian host
  rather than a guess.
- **Response streaming is deferred.** Requests are non-streaming, so a provider
  that only streams is not supported yet. Nothing in the gate depends on it.
- The full `shinobi` image still needs a graphical live-boot test: confirm
  SDDM, Hyprland, Quickshell, and keybindings work together in a real session.
- Which additional recon tools get MCP wrappers, and in what order —
  proposed next: `gobuster`/`ffuf` (web content discovery), `nikto`,
  `whatweb`, Metasploit RPC. Each is a judgment call about what's safe to
  expose read-only vs. what needs extra confirmation (anything
  exploitation-adjacent, e.g. Metasploit module execution, should require an
  explicit `--confirm` flag from the human, not just scope membership).
