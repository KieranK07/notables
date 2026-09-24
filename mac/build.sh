#!/bin/bash
# Builds Notables.app. No Xcode project — just swiftc plus a hand-assembled bundle.
#
#   ./build.sh            needs NOTABLES_PC_HOST (environment or ../notables.local)
#   ./build.sh --local    points the app at localhost instead
set -euo pipefail
LOCAL=0
for a in "$@"; do
  case "$a" in
    --local) LOCAL=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
ROOT="$(cd "$(dirname "$0")" && pwd)"

# The PC's tailnet address stays out of git. It comes from the environment or the
# gitignored notables.local at the repo root (NOTABLES_PC_HOST=<ip or MagicDNS name>),
# and is baked into a generated Swift file plus an ATS exception for plain HTTP.
[ -f "$ROOT/../notables.local" ] && . "$ROOT/../notables.local"
if [ "$LOCAL" = 1 ]; then
  PC_HOST=localhost
elif [ -n "${NOTABLES_PC_HOST:-}" ]; then
  PC_HOST="$NOTABLES_PC_HOST"
else
  echo "✗ NOTABLES_PC_HOST is unset. Put NOTABLES_PC_HOST=<pc-ip> in notables.local at the" >&2
  echo "  repo root, or run ./build.sh --local to build against localhost." >&2
  exit 1
fi

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

printf 'enum BuildConfig {\n    static let serverHost = "%s"\n}\n' "$PC_HOST" > "$BUILD_ROOT/BuildConfig.swift"
PB=/usr/libexec/PlistBuddy
PL="$APP/Contents/Info.plist"
$PB -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" "$PL"
$PB -c "Add :NSAppTransportSecurity:NSExceptionDomains:$PC_HOST dict" "$PL"
$PB -c "Add :NSAppTransportSecurity:NSExceptionDomains:$PC_HOST:NSExceptionAllowsInsecureHTTPLoads bool true" "$PL"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "› compiling"
swiftc \
  -O -whole-module-optimization \
  -swift-version 5 \
  -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Speech -framework WebKit -framework PDFKit -framework Quartz -framework QuickLookUI \
  $(find "$ROOT/Sources" -name '*.swift') "$BUILD_ROOT/BuildConfig.swift" \
  -o "$APP/Contents/MacOS/Notables"

echo "› signing (with entitlements)"
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
