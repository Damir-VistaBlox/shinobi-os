# KaliAI

AI integration for Kali Linux, in the spirit of Omarchy's AI integration for
Arch/Hyprland: a Hyprland desktop plus an agent wired in — but here the
valuable part isn't the themed terminal launcher, it's giving the agent safe,
scope-gated access to Kali's tool suite. See [`DESIGN.md`](./DESIGN.md) for
the full rationale and roadmap.

## What's here

- `bin/kaliai` — unified CLI dispatcher, ported from Omarchy's `omarchy`
  entrypoint: every `bin/kaliai-*` script is auto-discovered and reachable
  as `kaliai <group> [<name>] [args]`, self-documented from its own leading
  comments (run `kaliai help`). No logic of its own beyond routing — real
  behavior lives in the leaf scripts below, each independently callable too.
- `bin/kaliai-engagement`, `bin/kaliai-scope`, `bin/kaliai-agent` — manage
  "engagements" (scope + audit log) and launch the AI agent with the active
  one wired in.
- `bin/kaliai-default-agent`, `bin/kaliai-menu`, `bin/kaliai-theme`,
  `bin/kaliai-capture`, `bin/kaliai-power`, `bin/kaliai-audio`,
  `bin/kaliai-network`, `bin/kaliai-bluetooth`, `bin/kaliai-hypr-toggle` —
  desktop commands ported from Omarchy's equivalents (default-agent picker,
  wofi command palette, themed hypr/waybar/wofi/kitty, screenshots that save
  into the active engagement's evidence dir, session/power menu, audio/wifi/
  bluetooth OSD, Hyprland toggles). Need the Hyprland desktop stack to do
  anything — see `distro/`.
- `mcp-servers/kaliai-recon` — MCP server exposing Kali recon tools
  (currently: `nmap_scan`) as scope-checked, logged tool calls. Every call
  is validated against the active engagement's `scope.yaml` before it runs.
- `themes/` — `kali-dark` (default) and `matrix`, switched with `kaliai-theme`.
- `install.sh` — apt + pipx provisioning to add kaliai to an existing Kali box.
- `distro/` — builds a custom Kali live ISO (Hyprland desktop + kaliai
  pre-installed) on top of Kali's own official `live-build` tooling. See
  [`distro/README.md`](./distro/README.md).

## Quickstart

```
./install.sh
kaliai engagement new acme-pentest   # prints the scope.yaml path it created
$EDITOR <that path>                  # fill in client, dates, authorized targets
kaliai agent
```

(`kaliai engagement new` also activates the engagement it creates, so
`engagement use` is only needed to switch back to one later.)

Register `kaliai-recon` as an MCP server with your agent — see
`config/claude/mcp-servers.json` for a Claude Code example.

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
