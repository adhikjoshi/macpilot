#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacPilot.app"
APP_PATH="$ROOT_DIR/$APP_NAME"
BINARY_SRC="$ROOT_DIR/.build/release/macpilot"
BINARY_DST="$APP_PATH/Contents/MacOS/MacPilot"
PLIST_TEMPLATE="$ROOT_DIR/AppBundle/Info.plist"
PLIST_DST="$APP_PATH/Contents/Info.plist"
ENTITLEMENTS="$ROOT_DIR/AppBundle/macpilot.entitlements"
SIGN_IDENTITY="${MACPILOT_SIGN_IDENTITY:--}"

cd "$ROOT_DIR"

swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"
cp "$PLIST_TEMPLATE" "$PLIST_DST"

if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH"
fi

echo "Built app bundle: $APP_PATH"
echo "Bundle identifier: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_DST")"
echo "Executable: $BINARY_DST"
