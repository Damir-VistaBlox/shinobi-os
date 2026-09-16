#!/usr/bin/env bash
# Provision Shinobi OS on a Kali box: apt deps, shinobi CLI on PATH, shinobi-recon
# MCP server via pipx.
set -euo pipefail

SHINOBI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"

echo "== Installing apt dependencies =="
sudo apt-get update -y
sudo apt-get install -y nmap python3-pip pipx

echo "== Linking shinobi CLI into $PREFIX/bin =="
for script in "$SHINOBI_ROOT"/bin/shinobi*; do
  sudo ln -sf "$script" "$PREFIX/bin/$(basename "$script")"
done

echo "== Installing themes to /usr/share/shinobi/themes =="
sudo mkdir -p /usr/share/shinobi
sudo cp -r "$SHINOBI_ROOT/themes" /usr/share/shinobi/themes

echo "== Installing shinobi-recon MCP server (pipx) =="
pipx install --force "$SHINOBI_ROOT/mcp-servers/shinobi-recon"

echo ""
echo "Installed. Next steps:"
echo "  1. shinobi engagement new <name>   # then edit engagements/<name>/scope.yaml"
echo "  2. shinobi engagement use <name>"
echo "  3. Register shinobi-recon as an MCP server with your agent — see"
echo "     config/claude/mcp-servers.json for a Claude Code example."
echo "  4. shinobi agent"
echo ""
echo "This installs the CLI only. shinobi-menu/shinobi-theme/shinobi-capture/"
echo "shinobi-power need the Hyprland desktop stack (quickshell, wofi, grim, ...)"
echo "to do anything — either install it yourself, or use the full desktop"
echo "ISO in distro/ instead of this script."
