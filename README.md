# Shinobi OS

AI integration for Kali Linux, in the spirit of Omarchy's AI integration for
Arch/Hyprland: a Hyprland desktop plus an agent wired in — but here the
valuable part isn't the themed terminal launcher, it's giving the agent safe,
scope-gated access to Kali's tool suite. See [`DESIGN.md`](./DESIGN.md) for
the full rationale and roadmap.

The installed-system integration contract is documented in
[`docs/architecture.md`](./docs/architecture.md). It defines how Shinobi uses
Kali's apt, systemd, D-Bus, Wayland, PipeWire, NetworkManager, and BlueZ
interfaces without overwriting user configuration.

## What's here

- `bin/shinobi` — unified CLI dispatcher, ported from Omarchy's `omarchy`
  entrypoint: every `bin/shinobi-*` script is auto-discovered and reachable
  as `shinobi <group> [<name>] [args]`, self-documented from its own leading
  comments (run `shinobi help`). No logic of its own beyond routing — real
  behavior lives in the leaf scripts below, each independently callable too.
- `bin/shinobi-engagement`, `bin/shinobi-scope`, `bin/shinobi-agent` — manage
  "engagements" (scope + audit log) and launch the AI agent with the active
  one wired in.
- `bin/shinobi-doctor` — confirms the local recon runtime is installed and
  reports whether an engagement and scope are active.
- `bin/shinobi-default-agent`, `bin/shinobi-menu`, `bin/shinobi-theme`,
  `bin/shinobi-capture`, `bin/shinobi-power`, `bin/shinobi-audio`,
  `bin/shinobi-network`, `bin/shinobi-bluetooth`, `bin/shinobi-hypr-toggle` —
  desktop commands ported from Omarchy's equivalents (default-agent picker,
  wofi command palette, themed hypr/Quickshell/wofi/kitty, screenshots that save
  into the active engagement's evidence dir, session/power menu, audio/wifi/
  bluetooth OSD, Hyprland toggles). Need the Hyprland desktop stack to do
  anything — see `distro/`.
- `mcp-servers/shinobi-recon` — MCP server exposing Kali recon tools
  (currently: `nmap_scan`) as scope-checked, logged tool calls. Every call
  is validated against the active engagement's `scope.yaml` before it runs.
- `themes/` — `kali-dark` (default) and `matrix`, switched with `shinobi-theme`.
- `install.sh` — apt + pipx provisioning to add shinobi to an existing Kali box.
- `distro/` — builds a custom Kali live ISO (Hyprland desktop + shinobi
  pre-installed) on top of Kali's own official `live-build` tooling. See
  [`distro/README.md`](./distro/README.md).

## Quickstart

```
./install.sh
shinobi engagement new acme-pentest   # prints the scope.yaml path it created
$EDITOR <that path>                  # fill in client, dates, authorized targets
shinobi agent
```

(`shinobi engagement new` also activates the engagement it creates, so
`engagement use` is only needed to switch back to one later.)

Register `shinobi-recon` as an MCP server with your agent — see
`config/claude/mcp-servers.json` for a Claude Code example.

On the live desktop, press `Super+Space` for the Shinobi command palette and
run `shinobi doctor` to check the local runtime before starting an engagement.

## Safety model

Every MCP tool call that touches a target is checked against the active
engagement's `scope.yaml` (authorized hosts/CIDRs + a date window) before it
runs. Out-of-scope targets are refused, not warned about. Every call —
allowed or refused — is appended to `engagements/<name>/log.jsonl`. Engagement
data is git-ignored; it's client-confidential and doesn't belong in this repo.

## Status

MVP. One tool wrapped (`nmap_scan`) as the reference implementation of the
scope-gate + audit-log pattern. See "Deliberately not built yet" in
`DESIGN.md` for what's next and the open decisions (default agent, desktop
menu integration, which tools to wrap next).
