#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
APP_BUNDLE=${1:?Usage: sign_app_bundle.sh path/to/staged.app}
APP_INFO="$APP_BUNDLE/Contents/Info.plist"
EXTENSION_SOURCE="$ROOT_DIR/SafariSessionExtension"
EXTENSION_BUNDLE="$APP_BUNDLE/Contents/PlugIns/SafariSessionExtension.appex"

if [[ $(plutil -extract CFBundleIdentifier raw -o - "$APP_INFO") != local.wemakecode.gptaccountmanager ]]; then
  echo "Expected a staged GPT Account Manager app bundle" >&2
  exit 1
fi

SIGNING_IDENTITY=${GPT_ACCOUNT_MANAGER_SIGNING_IDENTITY-}
if [[ -z "$SIGNING_IDENTITY" ]]; then
  DEVELOPMENT_IDENTITIES=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
  if [[ "$DEVELOPMENT_IDENTITIES" == *$'\n'* ]]; then
    echo "Set GPT_ACCOUNT_MANAGER_SIGNING_IDENTITY to choose an Apple Development identity" >&2
    exit 1
  fi
  SIGNING_IDENTITY=$DEVELOPMENT_IDENTITIES
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Safari session extension unavailable without an Apple Development identity. Signing the app ad hoc." >&2
  codesign --force --sign - "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
  exit 0
fi

if [[ "$SIGNING_IDENTITY" == - || -e "$EXTENSION_BUNDLE" ]]; then
  echo "Expected a signing identity and an app staged without the Safari extension" >&2
  exit 1
fi

APP_EXECUTABLE=$(plutil -extract CFBundleExecutable raw -o - "$APP_INFO")
MINIMUM_MACOS=$(plutil -extract LSMinimumSystemVersion raw -o - "$APP_INFO")
ARCHITECTURES=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE")
read -r -a ARCHITECTURES <<< "$ARCHITECTURES"
SDK=$(xcrun --sdk macosx --show-sdk-path)
SCRATCH=$(mktemp -d "$ROOT_DIR/.build/safari-session-extension.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

EXTENSION_BINARIES=()
for ARCH in "${ARCHITECTURES[@]}"; do
  BINARY="$SCRATCH/SafariSessionExtension-$ARCH"
  xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-macosx$MINIMUM_MACOS" \
    -O -parse-as-library -application-extension -module-name SafariSessionExtension \
    -framework SafariServices -Xlinker -e -Xlinker _NSExtensionMain \
    "$EXTENSION_SOURCE/SafariWebExtensionHandler.swift" -o "$BINARY"
  EXTENSION_BINARIES+=("$BINARY")
done

mkdir -p "$EXTENSION_BUNDLE/Contents/MacOS"
lipo -create "${EXTENSION_BINARIES[@]}" -output "$EXTENSION_BUNDLE/Contents/MacOS/SafariSessionExtension"
EXTENSION_INFO="$EXTENSION_BUNDLE/Contents/Info.plist"
cp "$EXTENSION_SOURCE/Info.plist" "$EXTENSION_INFO"
for KEY in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
  plutil -insert "$KEY" -string "$(plutil -extract "$KEY" raw -o - "$APP_INFO")" "$EXTENSION_INFO"
done
ditto "$EXTENSION_SOURCE/Resources" "$EXTENSION_BUNDLE/Contents/Resources"

codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none \
  --entitlements "$EXTENSION_SOURCE/Sandbox.entitlements" "$EXTENSION_BUNDLE"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
