#!/bin/zsh
# Bloom Remote keeps its identity and data. Release builds use a commit; --fast snapshots edits.
# --no-install verifies only. --no-launch installs only. --launch restarts only Bloom Remote.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
source "$root/Tools/guard.sh"

ref=HEAD
ref_given=0
fast=0
install=1
launch=0
legacy_export=0
for arg in "$@"; do
  case "$arg" in
    --fast) fast=1 ;;
    --no-install) install=0 ;;
    --no-launch) launch=0 ;;
    --launch) launch=1 ;;
    -*) print -ru2 -- "Unknown option: $arg"; exit 1 ;;
    *)
      (( ! ref_given )) || { print -ru2 -- "Supply only one revision."; exit 1; }
      ref="$arg"; ref_given=1 ;;
  esac
done
if [[ "${BLOOM_REMOTE_BUILD_ONLY:-0}" == 1 ]]; then install=0; legacy_export=1; fi
(( install )) || launch=0
if (( fast && ref_given )); then
  print -ru2 -- "--fast builds current files and cannot be combined with a revision."
  exit 1
fi
resolved="$(git rev-parse --verify "$ref^{commit}")"
stamp="$resolved"
config=release
build_args=(-r)
destination="$HOME/Applications/Bloom Remote.app"
verify_remote_destination() {
  [[ ! -L "$destination" ]] || { print -ru2 -- "The Remote app destination must not be a symbolic link."; exit 1; }
  if [[ -e "$destination" ]]; then
    local identifier
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    [[ "$identifier" == be.spatie.bloom.remote ]] || { print -ru2 -- "The destination is not a Bloom Remote app."; exit 1; }
  fi
}
bloom_refuse_real_app "$destination"
if (( install )); then
  verify_remote_destination
  bloom_refuse_if_own_host "$destination" "$HOME/Library/Application Support/Bloom Remote/bloom.sqlite"
  if (( ! launch )) && [[ -n "$(bloom_app_pids "$destination")" ]]; then
    print -ru2 -- "Bloom Remote is running. Use --no-install, or --launch to restart it after verification."
    exit 1
  fi
fi

cache_base="$HOME/Library/Caches/BloomBuild/remote"
if (( fast )); then
  checkout_hash="$(printf '%s' "${root:A}" | shasum | cut -c1-12)"
  cache="$cache_base/$checkout_hash"
  config=debug; build_args=(--jobs 4); stamp="${resolved[1,8]}-working"
else
  cache="$cache_base/release"
fi
mkdir -p "$cache"
lock="$cache/lock"
if ! mkdir "$lock" 2>/dev/null; then
  print -ru2 -- "Another Remote build owns $lock. Remove it only if its previous build has stopped."
  exit 1
fi
work=""
stage=""
worktree_created=0
install_lock=""
export_lock=""
publish_stage=""
cleanup() {
  [[ -z "$publish_stage" ]] || rm -rf "$publish_stage"
  [[ -z "$stage" ]] || rm -rf "$stage"
  if (( worktree_created )); then git worktree remove --force "$work" 2>/dev/null || true; fi
  [[ -z "$install_lock" ]] || rmdir "$install_lock"
  [[ -z "$export_lock" ]] || rmdir "$export_lock"
  rmdir "$lock"
}
trap cleanup EXIT
if (( install )); then
  if ! mkdir "$cache_base/install.lock" 2>/dev/null; then
    print -ru2 -- "Another build is preparing to install Bloom Remote."; exit 1
  fi
  install_lock="$cache_base/install.lock"
fi
if (( fast )); then
  stage="$(mktemp -d "$cache/stage.XXXXXX")"
  work="$stage"
  python3 "$root/Tools/build-snapshot.py" snapshot "$root" "$work"
else
  work="$cache/src"
  git worktree add --detach "$work" "$resolved" >/dev/null
  worktree_created=1
fi

# Preserve the tested installer payload, never quietly replace it with an empty wizard.
# Protocol compatibility is rechecked by embed-server-setup.py during normal packaging.
archive="${BLOOM_LINUX_SERVER_ARCHIVE:-$destination/Contents/Resources/ServerSetup/server.tar.gz}"
if [[ ! -f "$archive" ]]; then
  print -ru2 -- "No Linux server package is available. Set BLOOM_LINUX_SERVER_ARCHIVE to a tested archive."
  exit 1
fi
cp "$archive" "$cache/server-package.tar.gz"
export BLOOM_LINUX_SERVER_ARCHIVE="$cache/server-package.tar.gz"
print -- "Linux installer payload: $archive"
print -- "Archive SHA-256: $(shasum -a 256 "$BLOOM_LINUX_SERVER_ARCHIVE" | awk '{print $1}')"
print -- "The Linux payload is reused, not rebuilt; matching protocol does not prove matching source."
python3 "$root/Tools/build-snapshot.py" check-inputs "$work" Resources/Info.plist Resources/Bloom.icon/icon.json
python3 "$root/Tools/prepare-remote-app.py" "$work" "$destination" "$stamp"
python3 "$root/Tools/icon/dev-tint.py" "$work/Resources/Bloom.icon/icon.json" 0.8
if (( fast )); then
  python3 "$root/Tools/build-snapshot.py" sync "$work" "$cache/src"
  rm -rf "$stage"; stage=""
  work="$cache/src"
fi
mkdir -p "$cache/build"
ln -sfn "$cache/build" "$work/.build"
rm -rf "$work/.build/$config/Bloom.app"
log="$cache/build.log"
print -- "Building Bloom Remote $stamp ($config), using $cache"
if ! (cd "$work" && BLOOM_BUILD_JOBS=4 ./Tools/build.sh "${build_args[@]}") > "$log" 2>&1; then
  cat "$log" >&2
  print -ru2 -- "Build failed. Nothing installed. Full log: $log"
  exit 1
fi
built="$work/.build/$config/Bloom.app"
[[ -d "$built" ]] || { print -ru2 -- "The build did not produce an app bundle. See $log"; exit 1; }
built="${built:A}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built/Contents/Info.plist")" == be.spatie.bloom.remote ]]
codesign --verify --deep --strict "$built"
if (( legacy_export )); then
  if ! mkdir "$cache_base/export.lock" 2>/dev/null; then print -ru2 -- "Another build is exporting Bloom Remote."; exit 1; fi
  export_lock="$cache_base/export.lock"
  publish_stage="$(mktemp -d /tmp/.Bloom-Remote-ready.XXXXXX)"
  ditto "$built" "$publish_stage"
  python3 "$root/Tools/install-built-app.py" "$publish_stage" /tmp/Bloom-Remote-ready.app
  publish_stage=""
  print -- "Ready to install /tmp/Bloom-Remote-ready.app at $stamp. Nothing installed or launched."
  exit 0
fi
if (( ! install )); then
  print -- "Built $built at $stamp. Nothing installed or launched. Full log: $log"
  exit 0
fi

mkdir -p "$HOME/Applications"
publish_stage="$(mktemp -d "$HOME/Applications/.Bloom Remote.installing.XXXXXX")"
ditto "$built" "$publish_stage"
codesign --verify --deep --strict "$publish_stage"
# Recheck immediately before any process or installed bundle is changed.
verify_remote_destination
bloom_refuse_if_own_host "$destination" "$HOME/Library/Application Support/Bloom Remote/bloom.sqlite"
if (( launch )); then
  if [[ -n "$(bloom_app_pids "$destination")" ]]; then
    /usr/bin/osascript - "$destination" <<'APPLESCRIPT'
on run arguments
    set appPath to item 1 of arguments
    with timeout of 10 seconds
        tell application appPath to quit
    end timeout
end run
APPLESCRIPT
  fi
  for attempt in {1..50}; do
    [[ -n "$(bloom_app_pids "$destination")" ]] || break
    sleep 0.2
  done
fi
if [[ -n "$(bloom_app_pids "$destination")" ]]; then
  print -ru2 -- "Bloom Remote is still running. Its installed bundle was not replaced."; exit 1
fi
python3 "$root/Tools/install-built-app.py" "$publish_stage" "$destination"
publish_stage=""
print -- "Installed $destination at $stamp"
if (( launch )); then open -g "$destination"; fi
