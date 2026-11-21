#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
APP_NAME="GPT Account Manager"
PRODUCT_NAME="GPTAccountManager"
BUILD_DIR="$ROOT_DIR/.build/distribution"
OUTPUT="$ROOT_DIR/dist/GPT-Account-Manager-$(date +%Y-%m-%d)-universal.dmg"

if [[ -e "$OUTPUT" || -e "$OUTPUT.sha256" ]]; then
  echo "Release already exists: $OUTPUT" >&2
  exit 1
fi

swift build --package-path "$ROOT_DIR" -c release --product "$PRODUCT_NAME" \
  --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR"
BIN_DIR=$(swift build --package-path "$ROOT_DIR" -c release --product "$PRODUCT_NAME" \
  --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR" --show-bin-path)
lipo "$BIN_DIR/$PRODUCT_NAME" -verify_arch arm64
lipo "$BIN_DIR/$PRODUCT_NAME" -verify_arch x86_64

if [[ ! -d "$ROOT_DIR/BrowserWorker/node_modules/playwright-core" ]]; then
  (cd "$ROOT_DIR/BrowserWorker" && npm ci --omit=dev --ignore-scripts)
fi

STAGE=$(mktemp -d "$ROOT_DIR/.build/dmg-XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP_BUNDLE="$STAGE/$APP_NAME.app"
RESOURCES="$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES/BrowserWorker/node_modules" "$ROOT_DIR/dist"
ditto "$BIN_DIR/$PRODUCT_NAME" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
# Copy only application resources; never copy Application Support, profiles or exports.
ditto "$ROOT_DIR/BrowserWorker/src" "$RESOURCES/BrowserWorker/src"
ditto "$ROOT_DIR/BrowserWorker/node_modules/playwright-core" "$RESOURCES/BrowserWorker/node_modules/playwright-core"
ditto "$ROOT_DIR/BrowserWorker/package.json" "$RESOURCES/BrowserWorker/package.json"
ditto "$ROOT_DIR/BrowserWorker/package-lock.json" "$RESOURCES/BrowserWorker/package-lock.json"
bash "$ROOT_DIR/script/make_app_icon.sh" "$ROOT_DIR/Assets/AppIcon.png" "$RESOURCES/AppIcon.icns"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$PRODUCT_NAME" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "local.wemakecode.gptaccountmanager" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleIconFile -string AppIcon "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "1.0.0" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "14.0" "$INFO_PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
plutil -insert NSAppTransportSecurity -xml '<dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>' "$INFO_PLIST"
plutil -lint "$INFO_PLIST"

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
ln -s /Applications "$STAGE/Applications"
ditto "$ROOT_DIR/docs/DMG-Установка.txt" "$STAGE/Установка.txt"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO "$OUTPUT"
hdiutil verify "$OUTPUT"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "Created: $OUTPUT"
