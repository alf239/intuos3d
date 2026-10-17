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
# macOS remembers the Input Monitoring / Accessibility grants by code signature. An ad-hoc signature changes
# on every rebuild, so sign with a self-signed code-signing certificate instead; create it on first install.
IDENTITY="intuos3d local code signing"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "Creating a local code-signing certificate '$IDENTITY' in your login keychain..."
  TMP="$(mktemp -d)"
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:intuos3d -name "$IDENTITY" 2>/dev/null
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P intuos3d -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
fi
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier local.intuos3d "$DEST/intuos3d" 2>&1 | grep -v 'replacing existing signature' || true
else
  echo "warning: could not create the certificate; ad-hoc signing (permissions must be re-granted after every rebuild)"
  codesign --force --sign - --identifier local.intuos3d "$DEST/intuos3d"
fi
sed "s|__HOME__|$HOME|g" LaunchAgent/local.intuos3d.plist > "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo
echo "intuos3d installed and started. Log: ~/Library/Logs/intuos3d.log"
echo "On first install macOS shows two permission dialogs for intuos3d (Input Monitoring and Accessibility)."
echo "Allow both; the driver opens the tablet by itself once Input Monitoring is granted."
echo "No dialog? Add this file by hand in System Settings > Privacy & Security > Input Monitoring and > Accessibility:"
echo "  $DEST/intuos3d"
