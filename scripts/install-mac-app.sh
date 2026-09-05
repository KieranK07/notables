#!/bin/bash
# Installs Notables.app into /Applications and registers it to start at login.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${NOTABLES_BUILD_DIR:-$HOME/Library/Caches/notables-build}/Notables.app"

[ -d "$APP" ] || { echo "Build it first:  cd mac && ./build.sh"; exit 1; }

echo "› installing to /Applications"
osascript -e 'quit app "Notables"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Notables.app
cp -R "$APP" /Applications/Notables.app

echo "› registering login item"
osascript <<'OSA' >/dev/null
tell application "System Events"
    if exists login item "Notables" then delete login item "Notables"
    make login item at end with properties {path:"/Applications/Notables.app", hidden:false}
end tell
OSA

# The repo lives under Desktop, which is file-provider synced, so the built bundle
# reacquires com.apple.FinderInfo between build.sh's verify and this copy. codesign
# then rejects it -- and a broken signature silently costs the app its microphone
# entitlement. Strip and re-verify HERE, on the installed copy, before launching.
echo "› checking the installed signature"
xattr -cr /Applications/Notables.app
find /Applications/Notables.app -name '.DS_Store' -delete 2>/dev/null || true
if ! codesign --verify --deep --strict /Applications/Notables.app 2>/dev/null; then
  echo "  re-signing"
  cat > /tmp/notables-install.entitlements <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
ENT
  codesign --force --sign - --entitlements /tmp/notables-install.entitlements \
    --timestamp=none /Applications/Notables.app
fi
codesign --verify --deep --strict /Applications/Notables.app \
  || { echo "✗ installed app is not correctly signed - the mic will not work"; exit 1; }
codesign -d --entitlements - /Applications/Notables.app 2>/dev/null | grep -q audio-input \
  || { echo "✗ audio-input entitlement missing from the installed app"; exit 1; }
echo "  signature and entitlements verified"

echo "› launching"
# --background relaunches without bringing the app forward, so an iteration loop
# doesn't yank focus away from whatever Kieran is actually doing.
if [ "${1:-}" = "--background" ] || [ "${NOTABLES_BG_LAUNCH:-0}" = "1" ]; then
  open -g /Applications/Notables.app
else
  open /Applications/Notables.app
fi
echo "✓ Notables installed. It'll start automatically at login."
