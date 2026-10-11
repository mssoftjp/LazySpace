#!/usr/bin/env bash
# Compile the editable Icon Composer source, including the macOS 14/15 fallback.
# Usage: script/compile-icon.sh /path/to/LazySpace.app (before signing)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="${1:?usage: compile-icon.sh /path/to/LazySpace.app}"
PLIST="$APP/Contents/Info.plist"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
ICON_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp/}lazyspace-icon.XXXXXX")"
trap 'rm -rf "$ICON_OUTPUT"' EXIT

xcrun actool "$ROOT/Assets/LazySpace.icon" \
  --compile "$ICON_OUTPUT" --platform macosx \
  --minimum-deployment-target "$MINIMUM" --app-icon LazySpace \
  --output-partial-info-plist "$ICON_OUTPUT/icon-info.plist" \
  --output-format human-readable-text --warnings --notices

mkdir -p "$APP/Contents/Resources"
cp "$ICON_OUTPUT/Assets.car" "$ICON_OUTPUT/LazySpace.icns" "$APP/Contents/Resources/"
python3 - "$PLIST" "$ICON_OUTPUT/icon-info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

target = Path(sys.argv[1])
info = plistlib.loads(target.read_bytes())
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
target.write_bytes(plistlib.dumps(info, sort_keys=False))
PY
/usr/bin/plutil -lint "$PLIST" >/dev/null
