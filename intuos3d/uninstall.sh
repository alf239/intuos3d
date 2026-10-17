#!/bin/sh
set -u
launchctl bootout "gui/$(id -u)/local.intuos3d" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.intuos3d.plist"
rm -rf "$HOME/Library/Application Support/intuos3d"
echo "intuos3d removed (unplug and replug the tablet to return it to mouse mode)."
