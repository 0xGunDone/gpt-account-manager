#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${GPTAM_NEW_PASSWORD+x}" ]]; then
  export -n GPTAM_NEW_PASSWORD
fi

ROOT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
cd "$ROOT_DIR"

if ! /bin/bash "$ROOT_DIR/script/update_on_launch.sh" sync "$ROOT_DIR"; then
  printf '%s\n' 'Could not synchronize the stable release. Building the local copy.' >&2
fi

if [[ -n "${GPTAM_NEW_PASSWORD+x}" ]]; then
  export GPTAM_NEW_PASSWORD
fi
exec "$ROOT_DIR/script/build_and_run.sh" "$@"
