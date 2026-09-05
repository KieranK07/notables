#!/usr/bin/env bash
# Screenshot the Notables window in place, without stealing focus.
#
#   ./scripts/shot.sh [output.png] [AppName]
#
# Needs Screen Recording permission for whatever runs it (System Settings ->
# Privacy & Security -> Screen Recording). Without it macOS silently returns a
# desktop-only image, so this checks the result rather than trusting it.
set -euo pipefail
OUT="${1:-$HOME/Library/Caches/notables-build/shot.png}"
APP="${2:-Notables}"
HELPER="$HOME/Library/Caches/notables-build/windowid"
SRC="$(cd "$(dirname "$0")" && pwd)/windowid.swift"

mkdir -p "$(dirname "$HELPER")" "$(dirname "$OUT")"
if [ ! -x "$HELPER" ] || [ "$SRC" -nt "$HELPER" ]; then
  swiftc -O "$SRC" -o "$HELPER" 2>/dev/null
fi

ID="$("$HELPER" "$APP")" || { echo "!! $APP has no on-screen window (is it running?)" >&2; exit 1; }
rm -f "$OUT"
screencapture -x -o -l"$ID" "$OUT"

[ -s "$OUT" ] || { echo "!! screencapture produced nothing" >&2; exit 1; }
SIZE=$(stat -f%z "$OUT")
if [ "$SIZE" -lt 20000 ]; then
  echo "!! screenshot is only ${SIZE}b - Screen Recording permission is probably not granted" >&2
  echo "   System Settings -> Privacy & Security -> Screen Recording -> enable for your terminal" >&2
fi
echo "$OUT"
