#!/usr/bin/env bash
# Provision Shinobi OS on a Kali box: apt deps, shinobi CLI on PATH, shinobi-recon
# MCP server via pipx.
set -euo pipefail

SHINOBI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"

echo "== Installing apt dependencies =="
sudo apt-get update -y
sudo apt-get install -y nmap python3-pip pipx dpkg-dev

echo "== Building and installing canonical shinobi-core package =="
package="$SHINOBI_ROOT/shinobi-core.deb"
"$SHINOBI_ROOT/packaging/build-deb.sh" "$package"
sudo dpkg -i "$package"
rm -f "$package"

echo "== Installing shinobi-recon MCP server (pipx) =="
pipx install --force "$SHINOBI_ROOT/mcp-servers/shinobi-recon"

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
echo "This installs the CLI only. shinobi-menu/shinobi-theme/shinobi-capture/"
echo "shinobi-power need the Hyprland desktop stack (quickshell, wofi, grim, ...)"
echo "to do anything — either install it yourself, or use the full desktop"
echo "ISO in distro/ instead of this script."
