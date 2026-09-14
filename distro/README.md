# distro/ — custom KaliAI ISO

Builds a Kali Linux live ISO with a Hyprland desktop and the `kaliai` CLI +
`kaliai-recon` MCP server baked in. Built on top of Kali's own official build
tooling, not a from-scratch respin.

## Layout

- `kali-live/` — git submodule of
  [`gitlab.com/kalilinux/build-scripts/kali-live`](https://gitlab.com/kalilinux/build-scripts/kali-live),
  Kali's own `live-build` config (the same repo the Kali team uses to build
  official images). Untouched upstream — don't edit inside it, it gets
  overwritten by `git submodule update`.
- `overlay/` — our customization, layered onto the submodule at build time:
  - `kali-config/variant-kaliai/` — the new variant: package list (Hyprland
    stack + `kali-linux-default`) and build-time hooks.
  - `includes.chroot/` — static files copied onto the image: Hyprland/waybar/
    wofi/kitty dotfiles (`usr/share/kaliai-dotfiles/`, defaulted to the
    `kali-dark` theme), the waybar engagement-status script
    (`usr/local/bin/`), and a generated `opt/kaliai/` (see below).
- `../themes/` — theme definitions (`kali-dark`, `matrix`) each app's dotfiles
  source/import; installed to `/usr/share/kaliai/themes` and switched with
  `kaliai-theme set <name>`.
- `build.sh` — stages `overlay/` into the `kali-live` checkout, then execs
  `kali-live/build.sh --variant kaliai`.

## Why a variant, not a fork

Kali's `live-build` config supports per-variant package lists and hooks, but
only one shared `includes.chroot` (`kali-config/common/includes.chroot`) —
there's no per-variant includes tree. `distro/build.sh` handles this by
rsyncing `overlay/includes.chroot/` into the submodule's shared
`common/includes.chroot/` before building, and symlinking
`overlay/kali-config/variant-kaliai` into the submodule's `kali-config/`.
Both are done at build time, not committed into the submodule — so
`kali-live/` stays a clean, updatable upstream checkout.

**Caveat**: because the merge lands in the *shared* includes.chroot, this
particular submodule checkout is now tied to building `variant-kaliai`. If
you also want to build a stock Kali variant (e.g. `--variant xfce`) for
comparison, use a separate clean clone of `kali-live` for that, not this one.

## Where the kaliai CLI itself comes from

`bin/`, `mcp-servers/kaliai-recon`, and `themes/` at the repo root are the
single source of truth. `distro/build.sh` copies them into
`overlay/includes.chroot/opt/kaliai/` at build time (gitignored — it's a
generated staging copy, not a second copy to keep in sync). A build hook
(`variant-kaliai/hooks/live/0020-kaliai-tooling.chroot`) then installs
`kaliai-recon` into a venv, symlinks every `bin/kaliai*` script onto `$PATH`,
and installs `themes/` to `/usr/share/kaliai/themes`.

## Desktop commands on the built image

Every command below is independently callable (its own binary on `$PATH`)
*and* reachable through `kaliai <group> [<name>]` — `bin/kaliai` is a
dispatcher, ported from Omarchy's `omarchy` entrypoint, that auto-discovers
every `kaliai-*` script and routes to it; run `kaliai help` on the built
image for the generated list. Keybindings call the binary directly (skips
the routing hop); a person would more likely type the `kaliai <group>` form.

| Binary | Dispatcher route | What it does | Keybinding |
|---|---|---|---|
| `kaliai-agent [--pick]` | `kaliai agent` | Launch the default (or picked) AI agent in the active engagement | `SUPER+SHIFT+CTRL+A` |
| `kaliai-engagement <new\|list\|use>` | `kaliai engagement` | Scaffold/list/switch engagements | — |
| `kaliai-scope show` | `kaliai scope show` | Print the active engagement's scope | — |
| `kaliai-default-agent [name]` | `kaliai default agent` | Get/set the default agent | — |
| `kaliai-menu` | `kaliai menu` | wofi command palette | `SUPER+SPACE` |
| `kaliai-theme set <kali-dark\|matrix>` | `kaliai theme set ...` | Switch theme across Hyprland/waybar/wofi/kitty | — |
| `kaliai-capture <full\|region>` | `kaliai capture ...` | Screenshot into the active engagement's `evidence/` dir | `Print` / `SUPER+Print` |
| `kaliai-power menu` | `kaliai power menu` | Lock/logout/suspend/reboot/shutdown | `SUPER+ESCAPE` |
| `kaliai-audio <up\|down\|...>` | `kaliai audio ...` | Volume/mic with an OSD popup | Media keys (`bindl`, work on lock screen) |
| `kaliai-network <menu\|toggle\|status>` | `kaliai network ...` | Wi-Fi scan/connect/toggle via nmcli | `SUPER+N` |
| `kaliai-bluetooth <menu\|toggle\|status>` | `kaliai bluetooth ...` | Bluetooth device connect/power via bluetoothctl | `SUPER+B` |
| `kaliai-hypr-toggle <gaps\|opacity>` | `kaliai hypr toggle ...` | The two Hyprland toggles that need remembered state | `SUPER+G` / `SUPER+O` |

Fullscreen/center/pin use Hyprland's built-in dispatchers directly
(`SUPER+SHIFT+F`, `SUPER+C`, `SUPER+SHIFT+P`) — no wrapper script needed.

**Not done**: Plymouth boot-splash theming — authoring one is script-based
and only verifiable with an actual boot test, not possible from this dev
environment. `hooks/live/0040-login-theme.chroot` detects the installed SDDM
theme and logs whether it has a `background=` key, but deliberately doesn't
guess a value for it (color vs. image-path semantics vary per theme and
guessing wrong risks a blank login screen) — finish that by hand once you
can see the theme render on a real build.

## Building

**Requires a Debian/Kali-family host** (not this Arch machine) with
`live-build` installed, root/sudo, and real disk space — a full `-default`
Kali live build is commonly 15-30GB of scratch space and takes a while.
`kali-live/build.sh` checks for a Debian-based OS and refuses to run
otherwise.

```
git submodule update --init distro/kali-live
./distro/build.sh --verbose
```

Output lands in `distro/kali-live/images/`, per `kali-live`'s own
conventions.

## Before a real build

The package list in `overlay/kali-config/variant-kaliai/package-lists/kali.list.chroot`
has only been spot-checked against pkg.kali.org (hyprland, hypridle, hyprlock
confirmed in `kali-rolling`) — it has **not** been build-tested end to end.
Run it once on a real Kali box/VM/container first and expect to fix a package
name or two.
