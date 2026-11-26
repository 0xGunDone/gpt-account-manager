#!/bin/bash
set -euo pipefail
umask 077

APP_NAME='GPT Account Manager.app'
APP_EXECUTABLE=GPTAccountManager
APP_IDENTIFIER=local.wemakecode.gptaccountmanager
ORIGIN_URL=https://github.com/0xGunDone/gpt-account-manager.git
RELEASE_URL=https://api.github.com/repos/0xGunDone/gpt-account-manager/releases/latest
STABLE_REF=refs/gptam/stable
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
PROCESS_DEADLINE='
    use POSIX qw(setsid WNOHANG);
    use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + shift @ARGV;
    my $child = fork();
    die "Could not start command: $!\n" unless defined $child;
    if (!$child) {
      my $session = setsid();
      defined $session && $session == $$ or die "Could not isolate command: $!\n";
      exec @ARGV or die "Could not run command: $!\n";
    }
    while (1) {
      my $result = waitpid($child, WNOHANG);
      if ($result == $child) {
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
      }
      die "Could not wait for command: $!\n" if $result < 0;
      last if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
      sleep 0.1;
    }
    kill "TERM", -$child or kill "TERM", $child;
    sleep 0.2;
    kill "KILL", -$child or kill "KILL", $child;
    waitpid($child, WNOHANG);
    die "Command timed out\n";
'

# Keep the launch password out of Git, signing, and build subprocesses.
if [[ ${GPTAM_NEW_PASSWORD+x} ]]; then
  export -n GPTAM_NEW_PASSWORD
fi

fail() {
  printf 'Git startup update: %s\n' "$*" >&2
  exit 1
}

canonical_directory() {
  [[ -d "$1" && "$(cd -- "$1" && pwd -P)" == "$1" ]]
}

valid_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

git_environment() {
  local git_home="$1"
  shift
  /usr/bin/env -i PATH="$SYSTEM_PATH" HOME="$git_home" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
    "$@"
}

checkout_git() {
  git_environment "$HOME" /usr/bin/git -C "$root" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c submodule.recurse=false "$@"
}

release_git() {
  git_environment "$scratch" /usr/bin/git --git-dir="$scratch/release.git" "$@"
}

valid_checkout() {
  local origin
  [[ "$(checkout_git rev-parse --show-toplevel)" == "$root" ]] || return 1
  origin=$(checkout_git config --get-all remote.origin.url) || return 1
  case "$origin" in
    "$ORIGIN_URL"|https://github.com/0xGunDone/gpt-account-manager|\
    git@github.com:0xGunDone/gpt-account-manager.git|git@github.com:0xGunDone/gpt-account-manager|\
    ssh://git@github.com/0xGunDone/gpt-account-manager.git|ssh://git@github.com/0xGunDone/gpt-account-manager) ;;
    *) return 1 ;;
  esac
  [[ "$(checkout_git symbolic-ref --quiet HEAD)" == refs/heads/main &&
     "$(checkout_git for-each-ref --format='%(upstream:remotename) %(upstream:remoteref) %(upstream)' refs/heads/main)" == \
       'origin refs/heads/main refs/remotes/origin/main' ]]
}

clean_checkout() {
  local changes hidden
  changes=$(checkout_git status --porcelain=v1 --untracked-files=normal --ignore-submodules=none) || return 1
  [[ -z "$changes" ]] || return 1
  hidden=$(checkout_git ls-files -v | /usr/bin/sed -n '/^[a-zS] /p') || return 1
  [[ -z "$hidden" ]]
}

stable_commit() {
  checkout_git rev-parse --verify --quiet "$STABLE_REF" || :
}

checkout_matches() {
  valid_checkout &&
    [[ "$(checkout_git rev-parse --verify HEAD)" == "$1" && "$(stable_commit)" == "$2" ]] &&
    clean_checkout
}

bundle_commit() {
  /usr/bin/plutil -extract GPTAMBuildCommit raw -o - "$1/Contents/Info.plist"
}

valid_bundle() {
  local info="$1/Contents/Info.plist" commit
  canonical_directory "$1" && [[ -f "$info" && ! -L "$info" ]] || return 1
  [[ -x "$1/Contents/MacOS/$APP_EXECUTABLE" && ! -L "$1/Contents/MacOS/$APP_EXECUTABLE" ]] || return 1
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")" == "$APP_IDENTIFIER" &&
     "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info")" == "$APP_EXECUTABLE" ]] || return 1
  commit=$(bundle_commit "$1") || return 1
  valid_commit "$commit" && /usr/bin/codesign --verify --deep --strict "$1"
}

valid_stage() {
  local staged="$1" stage_dir="${1%/*}"
  [[ "${stage_dir%/*}" == "$root/.build" && "${stage_dir##*/}" =~ ^app-bundle\.[[:alnum:]]{6}$ &&
     "${staged##*/}" == "$APP_NAME" && ! -e "$stage_dir/Previous.app" && ! -L "$stage_dir/Previous.app" &&
     -x "$staged/Contents/Resources/update_on_launch.sh" && ! -L "$staged/Contents/Resources/update_on_launch.sh" ]] &&
    canonical_directory "$stage_dir" && valid_bundle "$staged"
}

same_signer() {
  local current_detail staged_detail requirement
  current_detail=$(/usr/bin/codesign -d -r- --verbose=2 "$installed" 2>&1) || return 1
  if [[ "$current_detail" == *$'\nSignature=adhoc\n'* ]]; then
    staged_detail=$(/usr/bin/codesign -d --verbose=2 "$1" 2>&1) || return 1
    [[ "$staged_detail" == *$'\nSignature=adhoc\n'* ]]
  else
    requirement=$(printf '%s\n' "$current_detail" | /usr/bin/sed -n 's/^designated => //p')
    [[ -n "$requirement" ]] && /usr/bin/codesign --verify --test-requirement "=$requirement" "$1"
  fi
}

latest_release_tag() {
  local response="$scratch/release.json"
  /usr/bin/env -i PATH="$SYSTEM_PATH" HOME="$scratch" LC_ALL=C /usr/bin/curl -q \
    --fail --silent --show-error --proto '=https' --connect-timeout 4 --max-time 8 \
    --max-filesize 2097152 --header 'Accept: application/vnd.github+json' \
    --output "$response" "$RELEASE_URL" || return 1
  /usr/bin/python3 -I -S - "$response" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as response:
    release = json.load(response)
if (
    not isinstance(release, dict)
    or release.get("draft") is not False
    or release.get("prerelease") is not False
):
    sys.exit("Expected a published stable GitHub release")
tag = release.get("tag_name")
published = release.get("published_at")
stable_version = r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
if not isinstance(published, str) or not published or not isinstance(tag, str) or not re.fullmatch(stable_version, tag):
    sys.exit("Expected a published release with a vX.Y.Z tag")
print(tag)
PY
}

fetch_canonical_tag() {
  local tag_ref="$1" local_objects
  release_git init --quiet --bare --template= || return 1
  local_objects=$(checkout_git rev-parse --path-format=absolute --git-path objects) || return 1
  [[ -d "$local_objects" && "$local_objects" != *$'\n'* ]] || return 1
  printf '%s\n' "$local_objects" > "$scratch/release.git/objects/info/alternates" || return 1

  # Limit Git and its HTTPS helper to one process group.
  git_environment "$scratch" /usr/bin/perl -e "$PROCESS_DEADLINE" 15 \
    /usr/bin/git --git-dir="$scratch/release.git" -c credential.helper= \
    -c protocol.allow=never -c protocol.https.allow=always -c http.followRedirects=false \
    -c core.hooksPath=/dev/null fetch --quiet --no-tags --no-recurse-submodules \
    --no-auto-gc -- "$ORIGIN_URL" "$tag_ref:$tag_ref"
}

sync_release() {
  local built_commit="${1-}" confirmed_tag="${2-}" confirmed_commit="${3-}" head previous tag tag_ref fetched
  release_tag=
  release_commit=
  valid_checkout && clean_checkout || fail 'Checkout must be clean with main tracking the public origin/main.'
  head=$(checkout_git rev-parse --verify HEAD)
  previous=$(stable_commit)

  scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gptam-fetch.XXXXXX")
  trap '/bin/rm -rf -- "$scratch"' EXIT
  tag=$(latest_release_tag) || fail 'Could not read the latest stable GitHub release.'
  if [[ -n "$confirmed_tag" ]]; then
    [[ "$tag" == "$confirmed_tag" ]] || fail 'The latest stable release changed after confirmation.'
    printf 'downloading\n'
  fi
  tag_ref="refs/tags/$tag"
  fetch_canonical_tag "$tag_ref" >&2 || fail "Could not fetch stable release tag $tag."
  fetched=$(release_git rev-parse --verify "$tag_ref^{commit}") || fail "Release $tag does not identify a commit."
  valid_commit "$fetched" || fail 'Invalid stable release commit.'
  [[ -z "$confirmed_tag" || "$fetched" == "$confirmed_commit" ]] || fail 'The release tag changed after confirmation.'
  checkout_matches "$head" "$previous" || fail 'Checkout changed during fetch.'
  if [[ -n "$previous" ]] && ! release_git merge-base --is-ancestor "$previous" "$fetched"; then
    fail 'Stable release does not descend from the previously accepted release.'
  fi
  if [[ "$head" != "$fetched" ]] && release_git merge-base --is-ancestor "$fetched" "$head"; then
    printf 'Local main is ahead of stable release %s. Keeping the current checkout.\n' "$tag" >&2
    return 0
  fi
  if [[ -n "$built_commit" ]]; then
    if [[ "$built_commit" != "$fetched" ]] && release_git merge-base --is-ancestor "$fetched" "$built_commit"; then
      return 0
    fi
    release_git merge-base --is-ancestor "$built_commit" "$fetched" || fail 'Stable release does not descend from the installed app.'
  fi
  release_git merge-base --is-ancestor "$head" "$fetched" || fail 'Local main diverges from the stable release.'
  if [[ "$mode" == check ]]; then
    release_tag="$tag"
    release_commit="$fetched"
    return 0
  fi
  if ! checkout_git cat-file -e "$fetched^{commit}" 2>/dev/null; then
    checkout_git -c protocol.allow=never -c protocol.file.allow=always fetch --quiet \
      --no-write-fetch-head --no-tags --no-recurse-submodules --no-auto-gc --refmap= \
      -- "$scratch/release.git" "$tag_ref" >&2 || fail 'Could not import the stable release commit.'
  fi
  checkout_matches "$head" "$previous" || fail 'Checkout changed before fast-forward.'
  if [[ "$head" != "$fetched" ]]; then
    checkout_git merge --ff-only --no-autostash --no-overwrite-ignore -- "$fetched" >&2 || fail 'Fast-forward failed.'
    printf 'Updated checkout to stable release %s.\n' "$tag" >&2
  fi
  checkout_matches "$fetched" "$previous" || fail 'Checkout changed during fast-forward.'
  if [[ "$previous" != "$fetched" ]]; then
    checkout_git update-ref -m "GPT Account Manager stable release $tag" "$STABLE_REF" "$fetched" "$previous" >&2
  fi
  release_commit="$fetched"
}

validate_installed_revision() {
  local built_commit="$1"
  valid_commit "$built_commit" || fail 'Invalid installed build commit.'
  [[ "$(bundle_commit "$installed")" == "$built_commit" ]] && valid_bundle "$installed" || fail 'Invalid installed app bundle.'
}

check_update() {
  local built_commit="$1"
  validate_installed_revision "$built_commit"
  sync_release "$built_commit"
  if [[ -n "$release_commit" && "$built_commit" != "$release_commit" ]]; then
    printf 'available\t%s\t%s\n' "$release_tag" "$release_commit"
  else
    printf 'current\n'
  fi
}

prepare_update() {
  local built_commit="$1" confirmed_tag="${2-}" confirmed_commit="${3-}" staged
  validate_installed_revision "$built_commit"
  if [[ $# == 3 ]]; then
    [[ -n "$confirmed_tag" ]] && valid_commit "$confirmed_commit" || fail 'Invalid release confirmation.'
  fi
  sync_release "$built_commit" "$confirmed_tag" "$confirmed_commit"
  [[ -n "$release_commit" && "$built_commit" != "$release_commit" ]] || return 0

  [[ -z "$confirmed_tag" ]] || printf 'building\n'
  /bin/mkdir -p -- "$root/.build"
  canonical_directory "$root/.build" || fail 'Invalid build directory.'

  # Finder's default PATH omits Homebrew and user-local Node installations.
  /usr/bin/env -i HOME="$HOME" PATH="$SYSTEM_PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:${PATH:-$SYSTEM_PATH}" \
    TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    GPT_ACCOUNT_MANAGER_SIGNING_IDENTITY="${GPT_ACCOUNT_MANAGER_SIGNING_IDENTITY:-}" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false /usr/bin/perl -e "$PROCESS_DEADLINE" 600 \
    /bin/zsh -f "$root/script/build_and_run.sh" --build-only \
    >"$scratch/build.log" || { /bin/cat "$scratch/build.log" >&2; fail 'Build failed.'; }
  /bin/cat "$scratch/build.log" >&2
  staged=$(/usr/bin/sed -n 's/^Staged app at //p' "$scratch/build.log")
  checkout_matches "$release_commit" "$release_commit" || fail 'Checkout changed during build.'
  valid_stage "$staged" && [[ "$(bundle_commit "$staged")" == "$release_commit" ]] && same_signer "$staged" ||
    fail 'Staged app failed path, commit, or signing checks.'
  [[ -z "$confirmed_tag" ]] || printf 'staged\t'
  printf '%s\n' "$staged"
}

no_app_running() {
  local status=0
  /usr/bin/pgrep -a -x "$APP_EXECUTABLE" >/dev/null || status=$?
  [[ $status == 1 ]]
}

open_installed() {
  (
    if [[ ${GPTAM_NEW_PASSWORD+x} ]]; then
      export GPTAM_NEW_PASSWORD
    fi
    /usr/bin/open "$installed" --args --skip-git-update-on-launch
  ) >&2
}

swap_bundles() {
  /usr/bin/python3 -I -S - "$installed" "$1" <<'PY' >&2
import ctypes
import os
import sys

rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int
RENAME_SWAP = 0x00000002
if rename(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), RENAME_SWAP) != 0:
    print(os.strerror(ctypes.get_errno()), file=sys.stderr)
    sys.exit(1)
PY
}

install_update() {
  local app_pid="$1" staged="$2" process_started target_commit
  [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid app PID.'
  # macOS pgrep excludes ancestors by default, including the app that launched this helper.
  [[ "$(/bin/ps -ww -p "$app_pid" -o comm=)" == "$installed/Contents/MacOS/$APP_EXECUTABLE" &&
     "$(/usr/bin/pgrep -a -x "$APP_EXECUTABLE")" == "$app_pid" ]] || fail 'Expected exactly one instance of the installed app.'
  process_started=$(/bin/ps -p "$app_pid" -o lstart=)
  canonical_directory "$root/.build" &&
    valid_bundle "$installed" && valid_stage "$staged" && same_signer "$staged" || fail 'App bundle validation failed.'
  target_commit=$(bundle_commit "$staged")
  checkout_matches "$target_commit" "$target_commit" || fail 'Checkout changed after build.'
  [[ "$(/usr/bin/stat -f %d "$root/dist")" == "$(/usr/bin/stat -f %d "${staged%/*}")" ]] || fail 'App bundles are on different volumes.'
  /usr/bin/python3 -I -S -c 'import ctypes; ctypes.CDLL(None).renamex_np' || fail 'Bundle exchange unavailable.'

  printf 'ready\n'
  local deadline=$((SECONDS + 20))
  while [[ "$(/bin/ps -p "$app_pid" -o lstart=)" == "$process_started" ]]; do
    (( SECONDS < deadline )) || fail 'Installed app did not quit.'
    /bin/sleep 0.2
  done
  no_app_running || fail 'Another app instance is running.'

  if ! checkout_matches "$target_commit" "$target_commit" || ! valid_stage "$staged" ||
     [[ "$(bundle_commit "$staged")" != "$target_commit" ]] ||
     ! valid_bundle "$installed" || ! same_signer "$staged"; then
    if no_app_running && valid_bundle "$installed"; then
      open_installed || fail 'Could not relaunch the installed app.'
    fi
    fail 'App or checkout changed before installation.'
  fi
  no_app_running || fail 'Another app instance is running.'

  if swap_bundles "$staged"; then
    if open_installed; then
      /bin/mv "$staged" "${staged%/*}/Previous.app"
      return 0
    fi
    no_app_running && swap_bundles "$staged" || fail "Previous app preserved at $staged."
  fi
  open_installed || fail 'Could not relaunch the previous app.'
  fail 'Update installation failed. Previous app relaunched.'
}

mode=${1-}
root=${2-}
[[ "$root" == /* && "$root" != *$'\n'* ]] && canonical_directory "$root" &&
  [[ ! -L "$root/.build" ]] || fail 'Invalid checkout path.'
installed="$root/dist/$APP_NAME"

case "$mode:$#" in
  sync:2) sync_release ;;
  check:3) canonical_directory "$root/dist" || fail 'Invalid dist directory.'; check_update "$3" ;;
  prepare:3|prepare:5)
    canonical_directory "$root/dist" || fail 'Invalid dist directory.'
    shift 2
    prepare_update "$@"
    ;;
  install:4) canonical_directory "$root/dist" || fail 'Invalid dist directory.'; install_update "$3" "$4" ;;
  *) fail 'Usage: sync <root>, check <root> <builtCommit>, prepare <root> <builtCommit> [<tag> <commit>], or install <root> <appPID> <stagedBundle>.' ;;
esac
