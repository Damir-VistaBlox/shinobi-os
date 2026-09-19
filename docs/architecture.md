# Shinobi OS platform architecture

Shinobi is a Kali/Debian desktop integration layer, not a replacement for the
operating system. Kali owns the kernel, packages, systemd, D-Bus, Wayland,
PipeWire, NetworkManager, BlueZ, and logind. Shinobi coordinates those stable
interfaces through the `shinobi` CLI, user services, themes, hooks, migrations,
and engagement tooling.

Configuration precedence is:

1. `/usr/share/shinobi/default` — package-owned defaults; do not edit.
2. `/etc/shinobi` — administrator overrides.
3. `~/.config/shinobi` — user overrides.
4. `$XDG_STATE_HOME/shinobi` — persistent runtime state.
5. `$XDG_RUNTIME_DIR/shinobi` — session-only state.

The live ISO uses the same package and command contract as an installed system,
but update, package mutation, and snapshot operations are unavailable in live
mode. Engagement state and evidence are kept in the user data directory and are
volatile unless persistence is configured by the user.

## Integration boundaries

- `apt` and `dpkg` are used only through Shinobi package/update commands.
- `systemd --user` owns the desktop services and migration lifecycle.
- Hyprland IPC is used for runtime compositor state and actions.
- D-Bus is used for portals, power, NetworkManager, BlueZ, PipeWire, and user
  service activation.
- Quickshell owns the persistent panel and desktop state presentation.
- Hooks are named, bounded events; they never receive arbitrary shell commands
  from the agent.
- MCP tools accept structured arguments, enforce engagement scope, and append
  both allowed and refused calls to the engagement audit log.

Use `shinobi config paths`, `shinobi version`, and `shinobi doctor --json` when
diagnosing an installation. User configuration should be changed through
`~/.config/shinobi` or the supported `shinobi` commands so package upgrades do
not overwrite it.
