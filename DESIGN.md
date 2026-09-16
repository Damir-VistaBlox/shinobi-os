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

No tool in this repo shells out to an arbitrary command string from the
model. Each MCP tool takes structured parameters (target, a closed set of
flags) and builds the argv itself — never string-interpolates model output
into a shell.

## MVP built now

- `bin/shinobi` — subcommands: `engagement new/list/use`, `scope show`,
  `agent` (launches the configured agent with the current engagement's
  MCP config wired in).
- `mcp-servers/shinobi-recon` — Python MCP server, one tool family (`nmap_scan`)
  as the proof of concept for the scope-gate + audit-log pattern. Built to
  make adding the next tool (gobuster, nikto, whatweb...) mechanical: each
  new tool is a thin function that calls the same `require_in_scope()` +
  `log_call()` helpers.
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
in-scope `nmap_scan` runs and logs `"verdict": "allowed"`, an out-of-scope
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
- The full `shinobi` image still needs a graphical live-boot test: confirm
  SDDM, Hyprland, Quickshell, and keybindings work together in a real session.
- Which additional recon tools get MCP wrappers, and in what order —
  proposed next: `gobuster`/`ffuf` (web content discovery), `nikto`,
  `whatweb`, Metasploit RPC. Each is a judgment call about what's safe to
  expose read-only vs. what needs extra confirmation (anything
  exploitation-adjacent, e.g. Metasploit module execution, should require an
  explicit `--confirm` flag from the human, not just scope membership).
