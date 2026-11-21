#!/bin/zsh
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
CLT_TESTING_PATH="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

if [[ -d "$CLT_TESTING_PATH/Testing.framework" ]]; then
  exec swift test \
    --package-path "$ROOT_DIR" \
    --enable-swift-testing \
    --disable-xctest \
    -Xswiftc -F \
    -Xswiftc "$CLT_TESTING_PATH" \
    "$@"
fi

exec swift test --package-path "$ROOT_DIR" "$@"
