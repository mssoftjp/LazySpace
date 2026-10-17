#!/usr/bin/env bash
# Bundles the app and the investigation probe into .app bundles with a development signature.
# Usage: script/build.sh [--release] [--no-test]
# Output goes to dist/dev/, never to /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG=debug
RUN_TESTS=1
for a in "$@"; do
  case "$a" in
    --release) CONFIG=release ;;
    --no-test) RUN_TESTS=0 ;;
  esac
done

if [[ "$RUN_TESTS" == 1 ]]; then
  swift test 2>&1 | grep -E "Executed|error|failed" | tail -5
fi
swift build --configuration "$CONFIG" 2>&1 | grep -E "error|warning: (var|unused|imm)|Compiling|Build" | tail -20
BIN="$(swift build --configuration "$CONFIG" --show-bin-path)"

# Development signature. Without DEVELOPMENT_SIGNING_IDENTITY (environment, or the untracked
# script/signing.local.sh), use the only Apple Development certificate in the keychain if there is
# exactly one, otherwise sign ad hoc (ad-hoc builds need Accessibility access granted again each build).
if [[ -z "${DEVELOPMENT_SIGNING_IDENTITY:-}" && -f "$ROOT/script/signing.local.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/script/signing.local.sh"
fi
if [[ -n "${DEVELOPMENT_SIGNING_IDENTITY:-}" ]]; then
  IDENTITY="$DEVELOPMENT_SIGNING_IDENTITY"
else
  # Other certificates may share the name, so count SHA-1 hashes and sign with the hash when there is one. Unreadable: ad hoc.
  FOUND="$( { /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true; } | awk '/"Apple Development: /{print $2}' | sort -u)"
  if [[ -n "$FOUND" && "$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')" == 1 ]]; then IDENTITY="$FOUND"; else IDENTITY="-"; fi
fi
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"

DEV_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/lazyspace-dev-entitlements.XXXXXX")"
trap 'rm -f "$DEV_ENTITLEMENTS"' EXIT
cat > "$DEV_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
PLIST

stage() { # name exe bundle_id ui_element
  local name="$1" exe="$2" bundle="$3" uielement="$4"
  local app="$ROOT/dist/dev/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$exe" "$app/Contents/MacOS/$name"
  # Each module's String Catalog is a resource bundle. Without them the app stops at its first text.
  cp -R "$BIN"/LazySpace_*.bundle "$app/Contents/Resources/"
  if [[ "$name" == LazySpace ]]; then
    # Lowercase CLI name, a symlink to the same executable. It cannot live in MacOS/ on a case-insensitive file system.
    mkdir -p "$app/Contents/Resources/bin"
    ln -sfn "../../MacOS/LazySpace" "$app/Contents/Resources/bin/lazyspace"
  fi
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Musashino Software</string>
<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
<key>CFBundleAllowMixedLocalizations</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><$uielement/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key>
<string>LazySpace uses Accessibility to arrange windows in the current Space. Window titles are used to match rules and are not saved in window records. Typed text is not recorded.</string>
</dict></plist>
PLIST
  if [[ "$name" == LazySpace ]]; then
    "$ROOT/script/compile-icon.sh" "$app"
  fi
  /usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null
  local entitlements=()
  if [[ "$name" == LazySpace ]]; then
    # No SUFeedURL: development builds never check for updates, but the app still links Sparkle.
    "$ROOT/script/embed-sparkle.sh" "$BIN" "$app" "$IDENTITY" --timestamp=none
    # An ad hoc signature has no team, so library validation would refuse the embedded framework. Development only.
    if [[ "$IDENTITY" == "-" ]]; then entitlements=(--entitlements "$DEV_ENTITLEMENTS"); fi
  fi
  /usr/bin/codesign --force --timestamp=none --options runtime ${entitlements[@]+"${entitlements[@]}"} --sign "$IDENTITY" "$app"
  /usr/bin/codesign --verify --strict "$app"
  echo "staged $app"
}

stage LazySpace LazySpace jp.lazyspace.app true
stage LazySpaceProbe lzprobe jp.lazyspace.probe true
echo "identity: $IDENTITY  version: $VERSION  config: $CONFIG"
