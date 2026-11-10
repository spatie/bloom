#!/bin/zsh
# Render navigation and alerts without displaying windows, using a disposable app and database.
set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/probe-app.sh
snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-workspace-links.XXXXXX")"
snapshot_app="$snapshot_root/Bloom Workspace Links.app"
bloom_prepare_probe_app "$snapshot_app" "be.spatie.bloom.workspace-link-snapshots" "Bloom Workspace Links"
/usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 bloomdev' "$snapshot_app/Contents/Info.plist"
codesign --force --deep --sign - "$snapshot_app" >/dev/null 2>&1
mkdir -p "$snapshot_root/repository"
git -C "$snapshot_root/repository" init -b main >/dev/null
git -C "$snapshot_root/repository" -c user.name=Snapshots -c user.email=snapshots@example.test -c commit.gpgsign=false commit --allow-empty -m Fixture >/dev/null
open -g -n -W -a "$snapshot_app" --stdout "$snapshot_root/render.log" --stderr "$snapshot_root/render-errors.log" --args --workspace-link-snapshots "$snapshot_root"
print -- "$snapshot_root"
