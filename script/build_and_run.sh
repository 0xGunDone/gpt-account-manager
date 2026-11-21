#!/bin/zsh
set -euo pipefail

if [[ -n "${GPTAM_NEW_PASSWORD+x}" ]]; then
  typeset +x GPTAM_NEW_PASSWORD
fi

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
PRODUCT_NAME="GPTAccountManager"
APP_NAME="GPT Account Manager"
INSTALLED_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
WORKER_ROOT="$ROOT_DIR/BrowserWorker"
BUILD_ONLY=false
VERIFY=false
PASSWORD_GROUP=""

if [[ "${1-}" == "--build-only" ]]; then
  BUILD_ONLY=true
  shift
fi

if [[ "${1-}" == "--verify" ]]; then
  VERIFY=true
  shift
fi

if [[ "${1-}" == "--password-group" ]]; then
  PASSWORD_GROUP="${2-}"
  if [[ ! "$PASSWORD_GROUP" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "A group UUID is required for --password-group" >&2
    exit 1
  fi
  shift 2
fi

build_commit=""
if [[ "$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)" == "$ROOT_DIR" ]] &&
   build_status=$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal --ignore-submodules=none) &&
   [[ -z "$build_status" ]]; then
  build_commit=$(git -C "$ROOT_DIR" rev-parse --verify HEAD)
fi

swift build --package-path "$ROOT_DIR" -c release "$@"
BIN_DIR=$(swift build --package-path "$ROOT_DIR" -c release "$@" --show-bin-path)

WORKER_LOCK="$WORKER_ROOT/node_modules/.gptam-package-lock.json"
if [[ ! -d "$WORKER_ROOT/node_modules/playwright-core" ]] ||
   ! cmp -s "$WORKER_ROOT/package-lock.json" "$WORKER_LOCK"; then
  (cd "$WORKER_ROOT" && npm ci --omit=dev --ignore-scripts)
  cp "$WORKER_ROOT/package-lock.json" "$WORKER_LOCK"
fi

mkdir -p "$ROOT_DIR/.build"
STAGING_DIR=$(mktemp -d "$ROOT_DIR/.build/app-bundle.XXXXXX")
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
PREVIOUS_BUNDLE="$STAGING_DIR/Previous.app"
cleanup_stage() {
  if [[ -e "$PREVIOUS_BUNDLE" && ! -e "$INSTALLED_BUNDLE" ]] &&
     ! mv "$PREVIOUS_BUNDLE" "$INSTALLED_BUNDLE"; then
    printf 'Previous app preserved at %s\n' "$PREVIOUS_BUNDLE" >&2
    return
  fi
  rm -rf "$STAGING_DIR"
}
trap cleanup_stage EXIT
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
ditto "$BIN_DIR/$PRODUCT_NAME" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
mkdir -p "$APP_BUNDLE/Contents/Resources/BrowserWorker"
ditto "$WORKER_ROOT/src" "$APP_BUNDLE/Contents/Resources/BrowserWorker/src"
ditto "$WORKER_ROOT/node_modules" "$APP_BUNDLE/Contents/Resources/BrowserWorker/node_modules"
ditto "$WORKER_ROOT/package.json" "$APP_BUNDLE/Contents/Resources/BrowserWorker/package.json"
ditto "$WORKER_ROOT/package-lock.json" "$APP_BUNDLE/Contents/Resources/BrowserWorker/package-lock.json"

"$ROOT_DIR/script/make_app_icon.sh" \
  "$ROOT_DIR/Assets/AppIcon.png" \
  "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$PRODUCT_NAME" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "local.wemakecode.gptaccountmanager" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleIconFile -string AppIcon "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "1.1.2" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "5" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "14.0" "$INFO_PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
plutil -insert NSAppTransportSecurity -xml '<dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>' "$INFO_PLIST"

if [[ -n "$build_commit" && "$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" == "$build_commit" ]] &&
   build_status=$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal --ignore-submodules=none) &&
   [[ -z "$build_status" ]]; then
  cp "$ROOT_DIR/script/update_on_launch.sh" "$APP_BUNDLE/Contents/Resources/update_on_launch.sh"
  plutil -insert GPTAMBuildCommit -string "$build_commit" "$INFO_PLIST"
fi

bash "$ROOT_DIR/script/sign_app_bundle.sh" "$APP_BUNDLE"
if $BUILD_ONLY; then
  trap - EXIT
  printf 'Staged app at %s\n' "$APP_BUNDLE"
  exit 0
fi

mkdir -p "$ROOT_DIR/dist"
if pgrep -x "$PRODUCT_NAME" >/dev/null; then
  echo "Quit GPT Account Manager before installing and launching this build." >&2
  exit 1
fi
if [[ -e "$INSTALLED_BUNDLE" ]]; then
  mv "$INSTALLED_BUNDLE" "$PREVIOUS_BUNDLE"
fi
mv "$APP_BUNDLE" "$INSTALLED_BUNDLE"
APP_BUNDLE="$INSTALLED_BUNDLE"
if [[ -n "${GPTAM_NEW_PASSWORD+x}" ]]; then
  export GPTAM_NEW_PASSWORD
fi
if [[ -n "$PASSWORD_GROUP" ]]; then
  open -n "$APP_BUNDLE" --args --skip-git-update-on-launch --change-passwords-in-group-id "$PASSWORD_GROUP"
else
  open -n "$APP_BUNDLE" --args --skip-git-update-on-launch
fi
unset GPTAM_NEW_PASSWORD

if $VERIFY; then
  for _ in 1 2 3 4 5; do
    pgrep -x "$PRODUCT_NAME" >/dev/null && exit 0
    sleep 1
  done
  echo "$APP_NAME did not remain running" >&2
  exit 1
fi
