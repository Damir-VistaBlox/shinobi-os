#!/usr/bin/env bash
# Provision Shinobi OS on a Kali box: build and install the layer packages,
# then apply the layer with the same engine the ISO and the installation wizard
# use.
#
#   ./install.sh                 core + desktop (the full layer)
#   ./install.sh --cli-only      core only, no desktop stack
#   ./install.sh --help
#
# This used to install the CLI and then tell you the desktop needed the ISO.
# That was the gap the layer had: the Hyprland dotfiles, the Plymouth theme and
# the wallpaper existed only inside the image build, so installing to a disk --
# by any means -- produced Kali's own desktop with none of Shinobi's. They ship
# in shinobi-desktop now, and applying them is shinobi-setup's job, the same as
# in the image.
set -euo pipefail

SHINOBI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cli_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --cli-only) cli_only=true; shift ;;
    -h | --help | '')
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$1' (try --help)" >&2
      exit 64
      ;;
  esac
done

packages=core
if [ "$cli_only" = false ]; then
  packages="core desktop"
fi

echo "== Installing apt dependencies =="
sudo apt-get update -y
# dpkg-dev for build-deb.sh. rsync for shinobi-setup, which applies the dotfiles
# with rsync -a --chown so the home directory cannot land root-owned.
sudo apt-get install -y dpkg-dev rsync

echo "== Building and installing the Shinobi layer =="
for pkg in $packages; do
  package="$SHINOBI_ROOT/shinobi-$pkg.deb"
  "$SHINOBI_ROOT/packaging/build-deb.sh" "$pkg" "$package"
  # apt, not dpkg -i. The packages depend on python3-mcp, python3-yaml and the
  # desktop stack; dpkg -i resolves nothing, so it unpacks, fails, and leaves
  # the package unconfigured with nothing installed. apt given a local .deb
  # pulls the Depends in first, which is also what lets each postinst's
  # self-check mean anything.
  sudo apt-get install -y "$package"
  rm -f "$package"
done

# Apply the layer: dotfiles into /etc/skel and the account's home, the Nerd
# Font, provenance.
#
# No account is renamed here. install.sh is run on machines somebody already
# administers, and renaming their login to match a branding decision is not a
# call a script makes for them -- shinobi-setup takes --rename-from, and says so
# on stderr when the account it found is still Kali's.
echo "== Applying the layer =="
sudo shinobi-setup apply

echo ""
echo "Installed. Next steps:"
echo "  1. shinobi engagement new <name>   # then edit engagements/<name>/scope.yaml"
echo "  2. shinobi engagement use <name>"
echo "  3. shinobi agent --accept-ungoverned-egress"
echo ""
echo "The launcher registers the shinobi-recon MCP server with your agent for"
echo "you, so its tools are the ones behind Shinobi's scope gate. It will not"
echo "start an agent without --accept-ungoverned-egress: an external agent calls"
echo "its model provider directly, outside Shinobi's egress gate, and that part"
echo "is not governed. To wire the server yourself instead, see"
echo "config/claude/mcp-servers.json and pass --no-wire-mcp."
echo ""
echo "Check what landed: shinobi-setup status"
if [ "$cli_only" = true ]; then
  echo "Note: --cli-only installed no desktop layer, so shinobi-menu,"
  echo "shinobi-theme and shinobi-capture have no Hyprland stack to run against."
fi