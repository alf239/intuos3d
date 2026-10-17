#!/bin/sh
# Builds intuos3d, installs it under ~/Library/Application Support/intuos3d and loads it as a launch agent.
set -eu
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/intuos3d"
AGENT="$HOME/Library/LaunchAgents/local.intuos3d.plist"

swift build -c release
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "gui/$(id -u)/local.intuos3d" 2>/dev/null || true
cp .build/release/intuos3d "$DEST/intuos3d"
# Stable identifier so the Accessibility / Input Monitoring grants survive rebuilds as well as they can.
codesign --force --sign - --identifier local.intuos3d "$DEST/intuos3d"
sed "s|__HOME__|$HOME|g" LaunchAgent/local.intuos3d.plist > "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "intuos3d installed and started. Log: ~/Library/Logs/intuos3d.log"
echo "Grant it Accessibility and Input Monitoring in System Settings > Privacy & Security when prompted."
