#!/bin/zsh
# Shared ownership and publication for installed builds. A failed candidate never replaces
# the last working app, and caches and destinations each have one writer across checkouts.
BLOOM_BUILD_LOCKS=()
BLOOM_BUILD_CLEANUP_PATHS=()
BLOOM_BUILD_WORKTREE=""
BLOOM_BUILD_STAGE=""
BLOOM_PUBLICATION_STAGE=""
BLOOM_BUILD_TOOLS="${${(%):-%N}:A:h}"

bloom_build_cleanup() {
  # zsh can skip EXIT when errexit unwinds a function. ZERR covers that path too.
  trap - ZERR
  setopt localoptions noerrexit
  [[ -z "$BLOOM_PUBLICATION_STAGE" ]] || rm -rf "$BLOOM_PUBLICATION_STAGE"
  [[ -z "$BLOOM_BUILD_STAGE" ]] || rm -rf "$BLOOM_BUILD_STAGE"
  if [[ -n "$BLOOM_BUILD_WORKTREE" ]]; then
    git worktree remove --force "$BLOOM_BUILD_WORKTREE" 2>/dev/null || true
  fi
  local lock candidate
  for candidate in "${BLOOM_BUILD_CLEANUP_PATHS[@]}"; do rm -rf "$candidate"; done
  BLOOM_BUILD_CLEANUP_PATHS=()
  for lock in "${BLOOM_BUILD_LOCKS[@]}"; do rmdir "$lock"; done
  BLOOM_BUILD_LOCKS=()
  BLOOM_PUBLICATION_STAGE=""
  BLOOM_BUILD_STAGE=""
  BLOOM_BUILD_WORKTREE=""
}
trap bloom_build_cleanup EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

bloom_build_lock() {
  local lock="$1"
  mkdir -p "${lock:h}"
  if ! mkdir "$lock" 2>/dev/null; then
    print -ru2 -- "Another build owns $lock. Remove it only after its build has stopped."
    return 1
  fi
  BLOOM_BUILD_LOCKS+=("$lock")
}

bloom_verify_app_identity() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import plistlib, sys
bundle = Path(sys.argv[1])
if bundle.is_symlink():
    raise SystemExit('The app destination must not be a symbolic link')
if bundle.exists():
    with (bundle / 'Contents/Info.plist').open('rb') as source:
        if plistlib.load(source).get('CFBundleIdentifier') != sys.argv[2]:
            raise SystemExit('The app bundle has an unexpected identity')
PY
}

bloom_sign_built_app() {
  codesign --force --deep --sign "${BLOOM_CODESIGN_IDENTITY:-${BATON_CODESIGN_IDENTITY:--}}" "$1"
  codesign --verify --deep --strict "$1"
}

bloom_publish_built_app() {
  local built="$1" destination="$2" identifier="$3" database="$4" launch="$5" attempt
  bloom_verify_app_identity "$built" "$identifier"
  codesign --verify --deep --strict "$built"
  bloom_verify_app_identity "$destination" "$identifier"
  bloom_refuse_if_own_host "$destination" "$database"
  if (( ! launch )) && [[ -n "$(bloom_app_pids "$destination")" ]]; then
    print -ru2 -- "The app is running. Quit it before installing with --no-launch. Nothing installed."
    return 1
  fi
  mkdir -p "${destination:h}"
  BLOOM_PUBLICATION_STAGE="$(mktemp -d "${destination:h}/.Bloom.installing.XXXXXX")"
  ditto "$built" "$BLOOM_PUBLICATION_STAGE"
  codesign --verify --deep --strict "$BLOOM_PUBLICATION_STAGE"
  bloom_verify_app_identity "$BLOOM_PUBLICATION_STAGE" "$identifier"
  bloom_verify_app_identity "$destination" "$identifier"
  bloom_refuse_if_own_host "$destination" "$database"
  if (( launch )) && [[ -n "$(bloom_app_pids "$destination")" ]]; then
    osascript - "$destination" <<'APPLESCRIPT'
on run arguments
    set appPath to item 1 of arguments
    with timeout of 10 seconds
        tell application appPath to quit
    end timeout
end run
APPLESCRIPT
    for attempt in {1..50}; do
      [[ -n "$(bloom_app_pids "$destination")" ]] || break
      sleep 0.2
    done
  fi
  if [[ -n "$(bloom_app_pids "$destination")" ]]; then
    print -ru2 -- "The app is still running. Its installed bundle was not replaced."
    return 1
  fi
  python3 "$BLOOM_BUILD_TOOLS/install-built-app.py" "$BLOOM_PUBLICATION_STAGE" "$destination"
  BLOOM_PUBLICATION_STAGE=""
}
