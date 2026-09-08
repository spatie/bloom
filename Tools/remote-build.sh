#!/bin/zsh
# Install a pinned Bloom Remote without replacing or restarting any other Bloom app.
# Usage: Tools/remote-build.sh [ref]. Connection presets use BLOOM_REMOTE_* environment variables.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/Tools/guard.sh"

ref="${1:-HEAD}"
resolved="$(git rev-parse "$ref")"
work=/tmp/bloom-remote-src
scratch=/tmp/bloom-remote-build
lock=/tmp/bloom-remote-build.lock
destination="$HOME/Applications/Bloom Remote.app"
bloom_refuse_real_app "$destination"
bloom_refuse_if_own_host "$destination" "$HOME/Library/Application Support/Bloom Remote/bloom.sqlite"
if [[ -n "$(bloom_app_pids "$destination")" ]]; then
  print -ru2 -- "Bloom Remote is running. Close that app before replacing its installed build."
  exit 1
fi
if ! mkdir "$lock" 2>/dev/null; then
  print -ru2 -- "Another Bloom Remote build owns $lock."
  exit 1
fi
cleanup() {
  git worktree remove --force "$work" 2>/dev/null || true
  rmdir "$lock"
}
trap cleanup EXIT
git worktree add --detach "$work" "$resolved" >/dev/null
python3 Tools/prepare-remote-app.py "$work" "$destination" "$resolved"
python3 Tools/icon/dev-tint.py "$work/Resources/Bloom.icon/icon.json" 0.8
mkdir -p "$scratch"
ln -s "$scratch" "$work/.build"
print -- "Building Bloom Remote at ${resolved[1,8]}"
if ! (cd "$work" && BLOOM_BUILD_JOBS=4 ./Tools/build.sh -r) > /tmp/bloom-remote-build.log 2>&1; then
  tail -80 /tmp/bloom-remote-build.log >&2
  exit 1
fi
built="$work/.build/release/Bloom.app"
[[ -d "$built" ]] || { print -ru2 -- "The build did not produce an app bundle"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built/Contents/Info.plist")" == be.spatie.bloom.remote ]]
codesign --verify --deep --strict "$built"
mkdir -p "$HOME/Applications"
staging="$HOME/Applications/.Bloom Remote.installing.app"
rm -rf "$staging"
ditto "$built" "$staging"
rm -rf "$destination"
mv "$staging" "$destination"
print -- "Installed $destination at ${resolved[1,8]}"
