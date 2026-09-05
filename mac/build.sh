#!/bin/bash
# Builds Notables.app. No Xcode project — just swiftc plus a hand-assembled bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Build OUTSIDE the repo. The repo lives under Desktop, which is file-provider
# synced, and the provider re-stamps com.apple.FinderInfo onto the bundle in the
# window between `xattr -cr` and `codesign --verify` — so signing here can never be
# made reliably clean, no matter how many times the metadata is stripped.
BUILD_ROOT="${NOTABLES_BUILD_DIR:-$HOME/Library/Caches/notables-build}"
APP="$BUILD_ROOT/Notables.app"
mkdir -p "$BUILD_ROOT"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "› compiling"
swiftc \
  -O -whole-module-optimization \
  -swift-version 5 \
  -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Speech -framework WebKit -framework PDFKit -framework Quartz -framework QuickLookUI \
  $(find "$ROOT/Sources" -name '*.swift') \
  -o "$APP/Contents/MacOS/Notables"

echo "› signing (ad-hoc, with entitlements)"
# codesign refuses bundles carrying Finder metadata; a running app and copied
# resources both reintroduce it, so strip and verify rather than assume.
xattr -cr "$APP"
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
cat > /tmp/notables.entitlements <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
ENT
# Prefer a real signing identity over ad-hoc. Ad-hoc leaves TeamIdentifier unset,
# which costs the app any system integration keyed to app identity (and makes
# Gatekeeper grumpier). Override with NOTABLES_SIGN_ID, or set it to "-" to force
# ad-hoc.
SIGN_ID="${NOTABLES_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -E 'Apple Development|Developer ID Application' \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*([A-F0-9]+).*/\1/')"
fi
[ -n "$SIGN_ID" ] || SIGN_ID="-"
if [ "$SIGN_ID" = "-" ]; then echo "  identity: ad-hoc"; else echo "  identity: $SIGN_ID"; fi

codesign --force --sign "$SIGN_ID" --entitlements /tmp/notables.entitlements --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" || { echo "✗ signature verification failed"; exit 1; }

echo "✓ built $APP"
