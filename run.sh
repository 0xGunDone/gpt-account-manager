#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${GPTAM_NEW_PASSWORD+x}" ]]; then
  export -n GPTAM_NEW_PASSWORD
fi

ROOT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
cd "$ROOT_DIR"

if [[ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$ROOT_DIR" ]]; then
  printf '%s\n' 'No Git checkout at the project root. Launching the local copy.' >&2
elif ! branch=$(git symbolic-ref --quiet HEAD); then
  printf '%s\n' 'Detached Git HEAD. Launching the local copy.' >&2
elif ! read -r remote upstream_ref < <(
  git for-each-ref --format='%(upstream:remotename) %(upstream:remoteref)' "$branch"
) || [[ -z "$remote" || -z "$upstream_ref" ]]; then
  printf '%s\n' 'No Git upstream configured. Launching the local copy.' >&2
elif ! changes=$(git status --porcelain --untracked-files=normal --ignore-submodules=none); then
  printf '%s\n' 'Could not read Git status. Launching the local copy.' >&2
elif [[ -n "$changes" ]]; then
  printf '%s\n' 'Local changes detected. Launching the local copy.' >&2
elif ! GIT_TERMINAL_PROMPT=0 git fetch --no-tags --no-recurse-submodules -- "$remote" "$upstream_ref"; then
  printf '%s\n' 'Could not fetch the Git upstream. Launching the local copy.' >&2
elif [[ "$(git symbolic-ref --quiet HEAD)" != "$branch" ]]; then
  printf '%s\n' 'Git branch changed during fetch. Launching the local copy.' >&2
elif ! git -c submodule.recurse=false merge --ff-only --no-autostash --no-overwrite-ignore '@{upstream}'; then
  printf '%s\n' 'Git fast-forward failed. Launching the local copy.' >&2
fi

if [[ -n "${GPTAM_NEW_PASSWORD+x}" ]]; then
  export GPTAM_NEW_PASSWORD
fi
exec "$ROOT_DIR/script/build_and_run.sh" "$@"
