#!/usr/bin/env bash
# Copies Sparkle.framework from the SwiftPM build into APP/Contents/Frameworks and signs it from the inside out.
# Usage: script/embed-sparkle.sh BIN_DIR APP IDENTITY TIMESTAMP
#   TIMESTAMP is --timestamp (distribution) or --timestamp=none (development).
# Sign the app itself afterwards, without --deep.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:?BIN_DIR}" APP="${2:?APP}" IDENTITY="${3:?IDENTITY}" TIMESTAMP="${4:?TIMESTAMP}"
SOURCE="$BIN/Sparkle.framework"
LICENSE="$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE"
[[ -d "$SOURCE" ]] || { echo "Sparkle.framework is missing from $BIN. Run swift build first." >&2; exit 1; }
[[ -f "$LICENSE" ]] || { echo "Sparkle's LICENSE is missing. Run swift package resolve first." >&2; exit 1; }

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$FRAMEWORK"
/usr/bin/ditto "$SOURCE" "$FRAMEWORK"
# LazySpace is not sandboxed, so Sparkle's XPC services are not needed (Sparkle's sandboxing guide).
rm -rf "$FRAMEWORK/Versions/B/XPCServices" "$FRAMEWORK/XPCServices"
for code in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
  /usr/bin/codesign --force "$TIMESTAMP" --options runtime --sign "$IDENTITY" "$code"
done
# Sparkle's MIT license travels with every copy.
cp "$LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
