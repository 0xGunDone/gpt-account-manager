#!/bin/bash
set -euo pipefail
umask 077

APP_NAME='GPT Account Manager.app'
APP_EXECUTABLE=GPTAccountManager
APP_IDENTIFIER=local.wemakecode.gptaccountmanager
ORIGIN_URL=https://github.com/0xGunDone/gpt-account-manager.git
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin

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

checkout_git() {
  /usr/bin/env -i PATH="$SYSTEM_PATH" HOME="$HOME" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
    /usr/bin/git -C "$root" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c submodule.recurse=false "$@"
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

checkout_matches() {
  valid_checkout &&
    [[ "$(checkout_git rev-parse --verify HEAD)" == "$1" &&
       "$(checkout_git rev-parse --verify refs/remotes/origin/main)" == "$2" ]] &&
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

fetch_canonical_branch() {
  # Git has no overall HTTP deadline. Limit its own process group, including the HTTPS helper.
  /usr/bin/env -i PATH="$SYSTEM_PATH" HOME="$scratch" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false GIT_NO_REPLACE_OBJECTS=1 \
    /usr/bin/perl -e '
      use POSIX qw(setsid);
      my $child = fork();
      die "Could not start Git: $!\n" unless defined $child;
      if (!$child) {
        setsid() != -1 or die "Could not isolate Git: $!\n";
        exec @ARGV or die "Could not run Git: $!\n";
      }
      $SIG{ALRM} = sub {
        kill "TERM", -$child;
        select undef, undef, undef, 0.2;
        kill "KILL", -$child;
        die "Git fetch timed out\n";
      };
      alarm 15;
      waitpid $child, 0;
      alarm 0;
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' /usr/bin/git -c credential.helper= -c protocol.allow=never -c protocol.https.allow=always \
    -c http.followRedirects=false -c core.hooksPath=/dev/null clone --quiet --bare \
    --single-branch --branch main --no-tags --reference-if-able "$root" -- "$ORIGIN_URL" "$scratch/remote.git"
}

prepare_update() {
  local built_commit="$1" head tracking fetched staged
  valid_commit "$built_commit" || fail 'Invalid installed build commit.'
  valid_checkout && clean_checkout || fail 'Checkout must be clean with main tracking the public origin/main.'
  head=$(checkout_git rev-parse --verify HEAD)
  tracking=$(checkout_git rev-parse --verify refs/remotes/origin/main)
  checkout_git merge-base --is-ancestor "$head" "$tracking" || fail 'Local main has commits outside origin/main.'
  [[ "$(bundle_commit "$installed")" == "$built_commit" ]] && valid_bundle "$installed" || fail 'Invalid installed app bundle.'

  scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gptam-fetch.XXXXXX")
  trap '/bin/rm -rf -- "$scratch"' EXIT
  fetch_canonical_branch >&2 || fail 'Could not fetch public main.'
  fetched=$(checkout_git --git-dir="$scratch/remote.git" rev-parse --verify 'refs/heads/main^{commit}')
  valid_commit "$fetched" || fail 'Invalid public main commit.'
  checkout_matches "$head" "$tracking" || fail 'Checkout changed during fetch.'
  if ! checkout_git cat-file -e "$fetched^{commit}" 2>/dev/null; then
    checkout_git -c protocol.allow=never -c protocol.file.allow=always fetch --quiet \
      --no-write-fetch-head --no-tags --no-recurse-submodules --no-auto-gc --refmap= \
      -- "$scratch/remote.git" refs/heads/main >&2 || fail 'Could not import fetched commit.'
  fi
  checkout_git merge-base --is-ancestor "$tracking" "$fetched" || fail 'Public main no longer descends from origin/main.'
  checkout_matches "$head" "$tracking" || fail 'Checkout changed before fast-forward.'
  if [[ "$tracking" != "$fetched" ]]; then
    checkout_git update-ref -m 'GPT Account Manager startup update' refs/remotes/origin/main "$fetched" "$tracking" >&2
  fi
  if [[ "$head" != "$fetched" ]]; then
    checkout_matches "$head" "$fetched" || fail 'Checkout changed before fast-forward.'
    checkout_git merge --ff-only --no-autostash --no-overwrite-ignore -- "$fetched" >&2 || fail 'Fast-forward failed.'
  fi
  checkout_matches "$fetched" "$fetched" || fail 'Checkout does not match public main.'
  [[ "$built_commit" != "$fetched" ]] || return 0

  /bin/mkdir -p -- "$root/.build"
  canonical_directory "$root/.build" || fail 'Invalid build directory.'

  # Finder's default PATH omits Homebrew and user-local Node installations.
  /usr/bin/env -i HOME="$HOME" PATH="$SYSTEM_PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:${PATH:-$SYSTEM_PATH}" \
    TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    GPT_ACCOUNT_MANAGER_SIGNING_IDENTITY="${GPT_ACCOUNT_MANAGER_SIGNING_IDENTITY:-}" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false /bin/zsh -f "$root/script/build_and_run.sh" --build-only \
    >"$scratch/build.log" || { /bin/cat "$scratch/build.log" >&2; fail 'Build failed.'; }
  /bin/cat "$scratch/build.log" >&2
  staged=$(/usr/bin/sed -n 's/^Staged app at //p' "$scratch/build.log")
  checkout_matches "$fetched" "$fetched" || fail 'Checkout changed during build.'
  valid_stage "$staged" && [[ "$(bundle_commit "$staged")" == "$fetched" ]] && same_signer "$staged" ||
    fail 'Staged app failed path, commit, or signing checks.'
  printf '%s\n' "$staged"
}

no_app_running() {
  local status=0
  /usr/bin/pgrep -x "$APP_EXECUTABLE" >/dev/null || status=$?
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
  [[ "$(/bin/ps -ww -p "$app_pid" -o comm=)" == "$installed/Contents/MacOS/$APP_EXECUTABLE" &&
     "$(/usr/bin/pgrep -x "$APP_EXECUTABLE")" == "$app_pid" ]] || fail 'Expected exactly one instance of the installed app.'
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
  canonical_directory "$root/dist" && [[ ! -L "$root/.build" ]] || fail 'Invalid checkout path.'
installed="$root/dist/$APP_NAME"

case "$mode:$#" in
  prepare:3) prepare_update "$3" ;;
  install:4) install_update "$3" "$4" ;;
  *) fail 'Usage: prepare <root> <builtCommit> or install <root> <appPID> <stagedBundle>.' ;;
esac
