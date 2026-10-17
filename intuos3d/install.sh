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
# TCC keys ad-hoc binaries by code hash, so every rebuild would need re-granting. Sign with a local
# self-signed code-signing certificate when one exists (see README "Signing"), else fall back to ad-hoc.
IDENTITY="intuos3d local code signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier local.intuos3d "$DEST/intuos3d"
else
  echo "note: no '$IDENTITY' certificate in the keychain; ad-hoc signing (permissions reset on every rebuild)"
  codesign --force --sign - --identifier local.intuos3d "$DEST/intuos3d"
fi
sed "s|__HOME__|$HOME|g" LaunchAgent/local.intuos3d.plist > "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "intuos3d installed and started. Log: ~/Library/Logs/intuos3d.log"
echo "Grant it Accessibility and Input Monitoring in System Settings > Privacy & Security when prompted."
