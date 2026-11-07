#!/bin/bash
# Builds OldPhoneDeck.app and installs it in ~/Applications, then starts it.
# It runs in the menu bar and opens at login. Run this again to update.
#
#   scripts/install.sh              install or update
#   scripts/install.sh --uninstall  quit and remove the app (your settings in ~/.oldphonedeck stay)
#
# Environment: DEST (install folder, default ~/Applications), SIGN_IDENTITY (codesigning identity).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${DEST:-$HOME/Applications}"
APP="$DEST/OldPhoneDeck.app"

if [[ "${1:-}" == "--uninstall" ]]; then
  pkill -x OldPhoneDeck 2>/dev/null || true
  rm -rf "${APP:?}"
  echo "Removed $APP. Settings are still in ~/.oldphonedeck (delete that folder to remove them too)."
  exit 0
fi

echo "Building (release)…"
swift build -c release --product oldphonedeck
BIN="$(swift build -c release --show-bin-path)/oldphonedeck"

# Quit a running copy so the new one can use the ports.
pkill -x OldPhoneDeck 2>/dev/null && sleep 1 || true

echo "Assembling ${APP}..."
mkdir -p "$DEST"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OldPhoneDeck"
cp -R Sources/oldphonedeck/web "$APP/Contents/Resources/web"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OldPhoneDeck</string>
  <key>CFBundleDisplayName</key><string>OldPhoneDeck</string>
  <key>CFBundleIdentifier</key><string>com.oldphonedeck.app</string>
  <key>CFBundleExecutable</key><string>OldPhoneDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu-bar only: no Dock icon. -->
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>OldPhoneDeck reads what's playing in Spotify or Music and controls playback from your phone.</string>
</dict>
</plist>
PLIST

# Sign. A real identity (Apple Development / Developer ID) keeps macOS permissions like Accessibility
# across updates; with ad-hoc signing ("-") macOS may ask again after each reinstall.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -oE '"(Apple Development|Developer ID Application)[^"]*"' | tr -d '"' || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null
echo "Signed with: ${IDENTITY:-ad-hoc}"

open "$APP"
cat <<EOF

Installed and started: look for the OldPhoneDeck icon (a 2×2 grid) in the menu bar.
  • The first launch shows QR codes to pair your phone (menu → Pair a Phone… shows them again).
  • It opens at login (menu → Open at Login to turn that off).
  • macOS asks for Accessibility (Take note) and Automation (Spotify / Music) the first time they're used.
EOF
