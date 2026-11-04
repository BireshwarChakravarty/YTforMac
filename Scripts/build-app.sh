#!/usr/bin/env bash
# Builds Encore.app (and optionally a zip/DMG) with SwiftPM. Run on macOS 14+ with Xcode 16+.
#
#   ./Scripts/build-app.sh             # release build for this Mac's architecture
#   UNIVERSAL=1 ./Scripts/build-app.sh # Apple silicon + Intel
#   DMG=1 ./Scripts/build-app.sh       # also produce dist/Encore.dmg
#   INSTALL=1 ./Scripts/build-app.sh   # copy to /Applications when done
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/Encore.app"
CONFIG="${CONFIG:-release}"

echo "==> Checking Metal shaders"
"$ROOT/Scripts/check-shaders.sh" || { echo "Shader check failed"; exit 1; }

echo "==> Building ($CONFIG)"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64
  BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/Encore"
else
  swift build -c "$CONFIG"
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/Encore"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Encore"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT"/Resources/NightDrive/* "$APP/Contents/Resources/"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --verbose=2 "$APP"

(cd "$ROOT/dist" && rm -f Encore.zip && ditto -c -k --keepParent Encore.app Encore.zip)
echo "==> dist/Encore.zip"

if [[ "${DMG:-0}" == "1" ]]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$ROOT/dist/Encore.dmg"
  hdiutil create -volname "Encore" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/Encore.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "==> dist/Encore.dmg"
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  rm -rf /Applications/Encore.app
  cp -R "$APP" /Applications/
  xattr -cr /Applications/Encore.app || true
  echo "==> Installed to /Applications/Encore.app"
fi

echo "Done. Open with: open \"$APP\""
