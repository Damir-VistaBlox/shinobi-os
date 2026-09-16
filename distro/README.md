# distro/ — custom Shinobi OS ISO

Builds a Kali Linux live ISO with a Hyprland desktop and the `shinobi` CLI +
`shinobi-recon` MCP server baked in. Built on top of Kali's own official build
tooling, not a from-scratch respin.

## Layout

- `kali-live/` — git submodule of
  [`gitlab.com/kalilinux/build-scripts/kali-live`](https://gitlab.com/kalilinux/build-scripts/kali-live),
  Kali's own `live-build` config (the same repo the Kali team uses to build
  official images). Untouched upstream — don't edit inside it, it gets
  overwritten by `git submodule update`.
- `overlay/` — our customization, layered onto the submodule at build time:
  - `kali-config/variant-shinobi/` — the new variant: package list (Hyprland
    stack + `kali-linux-default`) and build-time hooks.
  - `includes.chroot/` — static files copied onto the image: Hyprland,
    Quickshell, wofi, and kitty dotfiles (`usr/share/shinobi-dotfiles/`,
    defaulted to the `kali-dark` theme), the default Shinobi wallpaper
    (`usr/share/backgrounds/shinobi-os/`), and a generated `opt/shinobi/`
    (see below).
  - `kali-config/variant-shinobi/hooks/live/0005-single-desktop.chroot` —
    exposes only the Hyprland session to SDDM, avoiding accidental fallback
    to a desktop session pulled in by an indirect dependency.
- `../themes/` — theme definitions (`kali-dark`, `matrix`) each app's dotfiles
  source/import; installed to `/usr/share/shinobi/themes` and switched with
  `shinobi-theme set <name>`.
- `build.sh` — stages `overlay/` into the `kali-live` checkout, then execs
  `kali-live/build.sh --variant shinobi`.

## Why a variant, not a fork

Kali's `live-build` config supports per-variant package lists and hooks, but
only one shared `includes.chroot` (`kali-config/common/includes.chroot`) —
there's no per-variant includes tree. `distro/build.sh` handles this by
rsyncing `overlay/includes.chroot/` into the submodule's shared
`common/includes.chroot/` before building, and symlinking
`overlay/kali-config/variant-shinobi` into the submodule's `kali-config/`.
Both are done at build time, not committed into the submodule — so
`kali-live/` stays a clean, updatable upstream checkout.

**Caveat**: because the merge lands in the *shared* includes.chroot, this
particular submodule checkout is now tied to building `variant-shinobi`. If
you also want to build a stock Kali variant (e.g. `--variant xfce`) for
comparison, use a separate clean clone of `kali-live` for that, not this one.

## Where the shinobi CLI itself comes from

`bin/`, `mcp-servers/shinobi-recon`, and `themes/` at the repo root are the
single source of truth. `distro/build.sh` copies them into
`overlay/includes.chroot/opt/shinobi/` at build time (gitignored — it's a
generated staging copy, not a second copy to keep in sync). A build hook
(`variant-shinobi/hooks/live/0020-shinobi-tooling.chroot`) then installs
`shinobi-recon` into a venv, symlinks every `bin/shinobi*` script onto `$PATH`,
and installs `themes/` to `/usr/share/shinobi/themes`.

## Desktop commands on the built image

Every command below is independently callable (its own binary on `$PATH`)
*and* reachable through `shinobi <group> [<name>]` — `bin/shinobi` is a
dispatcher, ported from Omarchy's `omarchy` entrypoint, that auto-discovers
every `shinobi-*` script and routes to it; run `shinobi help` on the built
image for the generated list. Keybindings call the binary directly (skips
the routing hop); a person would more likely type the `shinobi <group>` form.

| Binary | Dispatcher route | What it does | Keybinding |
|---|---|---|---|
| `shinobi-agent [--pick]` | `shinobi agent` | Launch the default (or picked) AI agent in the active engagement | `SUPER+SHIFT+CTRL+A` |
| `shinobi-engagement <new\|list\|use>` | `shinobi engagement` | Scaffold/list/switch engagements | — |
| `shinobi-scope show` | `shinobi scope show` | Print the active engagement's scope | — |
| `shinobi-doctor` | `shinobi doctor` | Check the local runtime and engagement state | — |
| `shinobi-default-agent [name]` | `shinobi default agent` | Get/set the default agent | — |
| `shinobi-menu` | `shinobi menu` | wofi command palette | `SUPER+SPACE` |
| `shinobi-theme set <kali-dark\|matrix>` | `shinobi theme set ...` | Switch theme across Hyprland/Quickshell/wofi/kitty | — |
| `shinobi-capture <full\|region>` | `shinobi capture ...` | Screenshot into the active engagement's `evidence/` dir | `Print` / `SUPER+Print` |
| `shinobi-power menu` | `shinobi power menu` | Lock/logout/suspend/reboot/shutdown | `SUPER+ESCAPE` |
| `shinobi-audio <up\|down\|...>` | `shinobi audio ...` | Volume/mic with an OSD popup | Media keys (`bindl`, work on lock screen) |
| `shinobi-network <menu\|toggle\|status>` | `shinobi network ...` | Wi-Fi scan/connect/toggle via nmcli | `SUPER+N` |
| `shinobi-bluetooth <menu\|toggle\|status>` | `shinobi bluetooth ...` | Bluetooth device connect/power via bluetoothctl | `SUPER+B` |
| `shinobi-hypr-toggle <gaps\|opacity>` | `shinobi hypr toggle ...` | The two Hyprland toggles that need remembered state | `SUPER+G` / `SUPER+O` |

Fullscreen/center/pin use Hyprland's built-in dispatchers directly
(`SUPER+SHIFT+F`, `SUPER+C`, `SUPER+SHIFT+P`) — no wrapper script needed.
The desktop provides `SUPER+SHIFT+V` for clipboard history and `SUPER+F1` for
the keybinding picker. Quickshell's engagement indicator is deliberately
prominent: it shows whether recon tooling has an active, scope-gated
engagement.

## Desktop stability

The image intentionally ships a single graphical session: Hyprland.
`kali-desktop-live` remains in the package list only for generic live-image
support; it does not install a competing desktop environment. At startup,
Hyprland exports its Wayland environment to D-Bus and the user systemd
instance before launching desktop services. Quickshell then runs under a
restart-on-failure user service, so a shell crash is recoverable within the
same login session. Portal routing is explicit: GTK provides general dialogs
such as file selection, while Hyprland owns screen capture and global
shortcuts.

The SDDM hook configures the Shinobi wallpaper through Kali Breeze's
supported `theme.conf.user` image-background override; the active theme and
that image-path setting were verified in a graphical live boot. **Not done**:
Plymouth boot-splash theming — authoring one is script-based and needs its
own live-boot validation.

## Building

**Requires a Debian/Kali-family host** (not this Arch machine) with
`live-build` installed, root/sudo, and real disk space — a full `-default`
Kali live build is commonly 15-30GB of scratch space and takes a while.
`kali-live/build.sh` checks for a Debian-based OS and refuses to run
otherwise.

Two variants, picked via `SHINOBI_VARIANT` (default `shinobi`, the full
desktop). **Build `shinobi-min` first** when validating changes — console
only, no desktop, and far less that can go wrong — before attempting
`shinobi`. Both variants have been built successfully; `shinobi-min` was also
boot-tested end to end. The full desktop image still needs a live graphical
boot test (see DESIGN.md's "staged build-out").

```
git submodule update --init distro/kali-live

# Stage B: console only — proves shinobi CLI + shinobi-recon bake correctly
SHINOBI_VARIANT=shinobi-min ./distro/build.sh --verbose

# Stage C: full Hyprland desktop, once the above works
./distro/build.sh --verbose
```

Output lands in `distro/kali-live/images/`, per `kali-live`'s own
conventions.

## Before a real build

The package list in `overlay/kali-config/variant-shinobi/package-lists/kali.list.chroot`
has been validated by a successful full-image build. Rebuild on a real Kali
box/VM after dependency updates: package availability in `kali-rolling` can
change over time.
