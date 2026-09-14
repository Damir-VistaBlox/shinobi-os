#!/usr/bin/env bash
# Provision KaliAI on a Kali box: apt deps, kaliai CLI on PATH, kaliai-recon
# MCP server via pipx.
set -euo pipefail

KALIAI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"

echo "== Installing apt dependencies =="
sudo apt-get update -y
sudo apt-get install -y nmap python3-pip pipx

echo "== Linking kaliai CLI into $PREFIX/bin =="
for script in "$KALIAI_ROOT"/bin/kaliai*; do
  sudo ln -sf "$script" "$PREFIX/bin/$(basename "$script")"
done

echo "== Installing themes to /usr/share/kaliai/themes =="
sudo mkdir -p /usr/share/kaliai
sudo cp -r "$KALIAI_ROOT/themes" /usr/share/kaliai/themes

echo "== Installing kaliai-recon MCP server (pipx) =="
pipx install --force "$KALIAI_ROOT/mcp-servers/kaliai-recon"

echo ""
echo "Installed. Next steps:"
echo "  1. kaliai engagement new <name>   # then edit engagements/<name>/scope.yaml"
echo "  2. kaliai engagement use <name>"
echo "  3. Register kaliai-recon as an MCP server with your agent — see"
echo "     config/claude/mcp-servers.json for a Claude Code example."
echo "  4. kaliai agent"
echo ""
echo "This installs the CLI only. kaliai-menu/kaliai-theme/kaliai-capture/"
echo "kaliai-power need the Hyprland desktop stack (waybar, wofi, grim, ...)"
echo "to do anything — either install it yourself, or use the full desktop"
echo "ISO in distro/ instead of this script."
