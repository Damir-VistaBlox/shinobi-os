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
timestamp, tool, args, target, and verdict. A third verdict, `error`, exists
for a call the policy allowed and the network did not deliver: a DNS failure or
a refused connection used to be recorded as `allowed`, which claimed an
authorized, completed call to a target that was never reached, and `refused`
would have asserted a policy denial that never happened. This is what makes "AI runs nmap
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
  `agent` (launches the configured agent against the current engagement: it
  requires an active engagement, exports the engagement name, the engagements
  root and the operator profile, records the launch, and hands over). It also
  does two things about governance that it used to leave entirely to the
  operator. It offers the agent the recon server, through the agent's own CLI
  (`shinobi mcp register`, using the same server resolution `shinobi llm` uses,
  so there is one server rather than two with one name), and it refuses to
  launch at all until the operator passes
  `--accept-ungoverned-egress`, because the agent's model traffic is not
  governed and the launcher will not imply that it is. Both facts — that the
  egress was acknowledged, and whether the server was wired, already present, or
  the agent has no way to be given one — go into the run record, so a launch
  that left the gate is findable afterwards rather than only visible on the
  terminal that ran it. `--no-wire-mcp` is the opt-out for an operator who has
  configured the server themselves.
- `bin/shinobi-mcp` + `libexec/shinobi/shinobi_control/mcpctl.py` — `resolve`
  answers how a server name resolves here, `register` offers it to an agent,
  `support` says whether an agent can be wired at all. Registration is the
  vendor CLI's own `mcp add`, with the syntaxes read off `claude mcp add
  --help` and `codex mcp add --help`: the formats are the vendors' to change,
  and a hand-written `mcpServers` entry that has quietly stopped being right
  looks exactly like a server that is registered and never being called. An
  existing registration is left alone rather than re-added.
- `providers/*.toml` — the LLM provider registry. Two wire shapes are
  implemented and validated, because they are the two the market settled on:
  OpenAI's `/chat/completions` and Anthropic's `/messages`. `api` says which,
  and the difference is more than cosmetic — the tool schema nests under
  `function.parameters` in one and sits at `input_schema` in the other, and the
  system prompt is a top-level field in one and the first message in the other.
  Getting either wrong yields a request the vendor accepts, with the tools
  silently ignored, which presents as a model that cannot call tools.

  `api` is deliberately not the same field as `egress`. `openai-compatible` is
  a protocol, not a vendor, so xAI, DeepSeek, Mistral and Groq all use it while
  remaining distinct cloud providers with their own keys, accounts and data
  paths. Conflating the two would make "speaks a standard API" mean "is
  somebody's cloud" and quietly waive the clearance that keeps client data off
  a third party.

  Shipped: `anthropic` (the Anthropic shape), `openai`, `xai`, `deepseek`,
  `mistral`, `groq` (OpenAI shape), and `ollama` and `vllm` as the two local
  examples. The self-hosted `vllm` manifest is the one to copy for a private
  inference server, because `reachable_on` is what makes the cloud exemption
  conditional on where the bytes actually go.
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

### Not ports: rebuilt around the threat model

Three subsystems have an Omarchy counterpart and are deliberately *not* ports of
it. Each was rewritten around what a tool on an engagement host should assume
about its own configuration, which is a question Omarchy — a personal desktop —
never has to ask:

- **`shinobi-webapp`** (`omarchy-webapp-*`) — HTTPS wrappers with isolated
  browser profiles, so a wrapped tool cannot reach the operator's real session.
  The stored record outlives the URL validation that created it, so `launch`
  re-validates everything it uses and resolves the browser fresh on every launch
  rather than reading it back from the record: anything able to edit that JSON — a
  restored backup, a synced config directory, a bug in another tool — would
  otherwise choose the program that runs.
- **`shinobi-plugin`** (`omarchy-*` plugin system) — plugins are *explicitly
  trusted*, and a manifest declares permissions (`filesystem`, `network`,
  `shell`, `privileged`, `microphone`, `camera`, `engagement-data`,
  `tool-execution`) that are validated rather than implied. A plugin here can
  reach engagement data and invoke recon tools; that is not a category of thing
  an operator should add by dropping a file in a directory.
- **`shinobi-capture`** — screenshots land in the active engagement's
  `evidence/` directory rather than `~/Pictures`, so material captured
  mid-engagement joins the same audit trail `shinobi-recon` writes to. Omarchy's
  equivalent has no reason to know what an engagement is.

See the categorized table from the design discussion (agent framework, menu,
webapp handler, voxtype = high value; theme, capture, notification/audio/
power = medium, worth adapting; package-mgmt wrapper, update/snapshot system,
hardware-quirks layer, consumer app installers, plugin system, dev tooling,
boot theming = low value / Arch-specific, skipped) for the full triage —
not reproduced here since it doesn't change often enough to duplicate.

That triage predates the shell work and is kept for its reasoning, not its
verdicts: the webapp handler, plugin system and update/snapshot system were all
marked skip-or-later and have since been built — the last two because this is an
installed system first, the first because a tool's web UI on an engagement host
needs a trust model Omarchy's does not have. Read it for why a decision was
originally declined, then read the sections above for what actually shipped.

## Three packages, one engine, three ways in

The layer ships as three Debian packages, and the whole system is that they have
one way of being applied:

| Package | Carries | Dependable by |
| --- | --- | --- |
| `shinobi-core` | CLI, control plane (user units), recon MCP server, tools, provider manifests, overlay repo tooling, archive keyring | anything |
| `shinobi-desktop` | Hyprland/Quickshell/wofi/kitty dotfiles, Plymouth theme, wallpaper, portal selection — **and the desktop stack's dependencies** | a desktop |
| `shinobi-installer` | The Shinobi Installation Wizard: Calamares configuration, branding, and the shellprocess steps | an image |

And one implementation of "put the layer on this machine", `shinobi-setup`,
called by three: the ISO build hook, `install.sh`, and the wizard's
`shellprocess@finish`. This is the part that is not obvious and was not always
true. Those three paths each carried their own copy of the provisioning logic,
they disagreed — the ISO's hook did things `install.sh`'s did not — and the
installed system was missing the entire desktop layer because that logic and the
files it applied lived in `includes.chroot`, which only exists while an image is
being built. Three install paths that each carry their own copy are three
layers, and only one of them was ever tested.

### Why the desktop stack's dependencies are in `Depends`

They used to be in the live image's package list, which is the only place they
were declared. That list is applied when an image is built, so an installed
system and the image it came from could not be compared — they were assembled
from two different sources, and nothing checked that they agreed. One declaration
now feeds both paths.

### Installing to disk

The Shinobi Installation Wizard is Calamares, branded, with an `unpackfs` flow.
The decision that everything else follows from: **what gets installed is the
system that is already running.** The package set `live-build` assembled, the
desktop layer from `shinobi-desktop`, the fonts fetched and checksum-verified
during the image build — the image is copied to the disk. A `packages` flow would
re-resolve all of that from a repository at the moment somebody picks a disk: a
second list to keep in sync with the image, a network dependency on an install
that currently has none, and a font it cannot reproduce at all, because that font
is in no archive.

Three consequences of installing a *live session* rather than assembling a
system, each handled explicitly in `shellprocess@prep` and `@finish`:

- The live session's own account comes across with the image, and Calamares
  cannot create an account that already exists. It is removed first — but only
  if it has no home directory, which is the signature of a copied live account.
- Its home and `/root` are excluded from the copy. The operator's home is built
  from `/etc/skel` instead, where the layer's dotfiles live.
- Its autologin configuration, if a future image ever grows one, would come
  across with it. A pentest distribution whose installed system logs itself in
  is a serious defect and is invisible until somebody boots the disk on a train,
  so the step that removes it is checked twice: once in what is excluded, once in
  what is deleted.

### The live account is created, not renamed

Kali's live image gets its account name from the kernel command line, and
live-config prefers that over anything in `/etc/live/config.conf.d`. So the boot
entries name it — `username=shinobi`, after Kali's parameters, because
live-config keeps the last value it sees — and live-config writes the sudoers
grant for that name itself. The earlier approach, `usermod -l` in a build hook
plus a rewrite of the sudoers rules that name the account, is kept only as a
fallback for an image that somehow still has a `kali` account.

It was not a close call. `usermod -l` on somebody who administers a machine is
not a decision a build script should make for them, which is why `shinobi-setup`
never renames an account unless asked for by name.

### What "installable" costs the other paths

An install must *coexist* rather than own, which is a stricter discipline than
the ISO gets for free: systemd user units rather than system units, credentials
in the kernel keyring on a live system and in a `0600` file otherwise,
`/etc/shinobi` data treated as the operator's, and postinsts that refuse to call
a package installed when it is not usable. Applying the layer does not overwrite
an operator's configuration either — homes are completed rather than synced, and
`--force` is required to overwrite.

## Deliberately not built yet

- **Voxtype** (voice typing) — genuinely useful for dictating engagement notes;
  low priority, not started. This is the only subsystem in Omarchy's inventory
  that is simply absent.
- **A single themed shell process.** Omarchy v4 "Quattro" merged the bar,
  launcher, menus, OSD, lock screen and polkit agent into one long-running
  Quickshell with a plugin architecture, replacing Waybar, Walker, Mako, hyprlock,
  hypridle, swaybg and polkit-gnome. Shinobi has a Quickshell bar plus a
  stateless wofi menu, because the menu port assumed no shell daemon to talk to.
  That assumption is now weaker than it was — `shinobi-shellctl` exists — so this
  is the largest remaining UX gap and worth a decision rather than a port.
- **Menu depth.** The palette is seven routes (agent, engagement, scope,
  clipboard, theme, keybindings, ...). Omarchy's is a nested, filterable JSONC
  palette that searches apps and commands from one surface. Same wofi mechanism,
  much less of it.
- **`refresh config`.** Omarchy can restore any shipped config file into
  `~/.config` on demand, so a broken setting is one command to recover rather
  than an archaeology exercise. Shinobi has no equivalent escape hatch.
- **Plymouth boot-splash theming** — shipped (it reaches installed systems now
  that it is in `shinobi-desktop`), but it has been seen exactly once, on a live
  boot. The image's journal was clean and the splash appeared; that is one
  observation, and the theme is script-based, so the remaining work is boots on
  hardware rather than code.
- **External agent CLIs are outside the egress gate. Their tools are not.**
  There are two gates, and an external agent was outside both at once.
  `shinobi agent` now closes the first: it registers the recon server with the
  agent through the agent's own CLI, so the tools it can reach are the ones
  behind `require_in_scope()`, the same approval and the same audit record the
  native client uses. What it cannot close is the second. A third-party binary
  opens its own connection to its model provider, using whatever endpoint and
  authentication it was configured with, and nothing in this tree is on that
  path. So the launcher now stops and says so, and launches only on an explicit
  acknowledgement that is recorded in the run record. That is a real reduction
  in the gap and it is not a closure: the launch is a decision, made knowingly
  and in writing, to run a model outside the gate. Closing it properly means
  intercepting or replacing a third-party binary's transport, which is a
  decision about what `shinobi agent` is for, not a patch. An agent the launcher
  cannot wire (`gemini`, `aider`, `opencode`) is launched with no Shinobi tools
  at all, and is told so on stderr rather than left to look armed.
- **The `.deb` carries the recon server.** It did not, which meant a real image
  and a checkout had tools while a bare `shinobi-core` install had none — and
  said so, pointing at `--server ''` rather than quietly running a toolless
  conversation. The blocker was never willingness but the dependency, and it is
  no longer a blocker: Kali rolling ships `python3-mcp` at 1.26.0, the major
  version this server imports (`mcp.server.fastmcp`), so the package depends on
  it instead of vendoring a pip install at install time.

  The server goes to `/usr/lib/shinobi/mcp-servers` with an entry point at
  `/usr/bin/shinobi-recon`, not into `dist-packages`. It is not a library other
  code should import: it is the component that enforces the scope gate and
  writes the audit log, and a `shinobi_recon` on the system import path could be
  shadowed by anything installed after it. That choice is also what removes the
  `dh_python3` question — there is no dist-packages path of ours to compute and
  no code of ours outside this package to byte-compile. `mcp` still comes from
  apt and is imported normally.

  Because Kali is rolling, `python3-mcp` will reach 2.x, where `fastmcp` no
  longer exists, and every `shinobi-recon` will fail to import. That failure is
  loud and fail-closed — never a silent ungoverned server — and the postinst
  checks for it rather than letting an unusable package look installed. Failing
  a postinst leaves the package unconfigured with the reason printed, so the
  repair is `apt install python3-mcp && dpkg --configure shinobi-core` instead
  of a reinstall. The check is a shipped script that resolves the server
  relative to itself, which is what lets `tests/test-package-layout.sh` exercise
  it against a staged tree instead of only ever against a real install.

  `python3-yaml` is now declared too, and it should have been all along: the
  egress policy and the scope policy are both parsed with it, so the control
  plane already shipped code that could not be imported on a host without it,
  and `shinobi egress check` was one import away from failing.
- **The status bar's `AI offline` is one word for four different states.** The
  panel reads the daemon socket and knows whether the broker is up, which is not
  the same question as whether a provider could be used. No key stored, an
  engagement that has not cleared cloud egress, and a trust profile below
  operator are three separate fixes, and an operator reading "offline" cannot
  act on any of them. `shinobi provider readiness` answers the question the bar
  was being asked, per provider and per blocker, and `shinobi doctor` prints the
  same report. It reuses the gate's own clearance reader so it cannot drift from
  what actually authorizes a request, and it deliberately does *not* call
  `authorize()` — a status command must never consume a per-turn approval.

  What it does not solve is selection: there is still no default provider, so
  every `shinobi llm ask` names one explicitly, and the desktop has nothing
  stable to bind to. That is defensible for the CLI and is the reason provider
  readiness is not surfaced in the panel yet.
- **Response streaming is deferred.** Requests are non-streaming, so a provider
  that only streams is not supported yet. Nothing in the gate depends on it.
- **The image builds, and this branch's first build ever is the one that proved
  it.** Run `36335285871` (2026-09-27, sha `03e85b2`) built the ISO and passed
  every step: live-build's chroot, the image's own contents, and BIOS/UEFI boot.
  That closed the two things only a chroot could answer — `apt-get install`
  resolves `python3-mcp` there, and the image ends up with the package's recon
  server and no second copy ahead of it on `PATH`.

  Worth recording how the first attempt failed, because the test suite could not
  have caught it: fifteen minutes of live-build, then
  `cp: cannot stat '/opt/shinobi/providers/.'`. `distro/build.sh` stages a subset
  of the repo into the chroot and the image hook builds the package from *that*,
  so a top-level path in `build-deb.sh` but not in the staging list is simply
  absent at build time — while the checkout has it, so every local check passes.
  `providers` arrived that way with the provider-registry stage. Green source
  checks had never meant this branch could build an image, and now they do;
  `tests/test-build-config.sh` compares the two lists so the next one is caught in
  seconds.

  **The boot tests are survival checks, not login tests.** Both logs read
  "remained alive for the timeout (serial console unavailable)" and "firmware-only
  serial output": the kernel came up and did not panic, under BIOS and under UEFI.
  Nobody has watched SDDM start, Hyprland come up, or `shinobi agent` run inside
  the image. That gap is the next one below, and it is a real one.
- **The full `shinobi` image still needs a graphical live-boot test:** confirm
  SDDM, Hyprland, Quickshell, and keybindings work together in a real session,
  and that `shinobi agent --accept-ungoverned-egress` wires the recon server
  into an agent *on the image*. The ISO has been built and booted to a live
  kernel; nothing past that has been observed.
- Which additional recon tools get MCP wrappers, and in what order —
  proposed next: `gobuster`/`ffuf` (web content discovery), `nikto`,
  `whatweb`, Metasploit RPC. Each is a judgment call about what's safe to
  expose read-only vs. what needs extra confirmation (anything
  exploitation-adjacent, e.g. Metasploit module execution, should require an
  explicit `--confirm` flag from the human, not just scope membership).
