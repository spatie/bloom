#!/bin/zsh
# The scroll lab: measures how the transcript scrolls, in invisible isolated copies of the app,
# against a synthetic corpus, and compares revisions with each other.
#
#   ./Tools/scroll-lab.sh build <ref>...       release builds with the lab compiled in, cached by commit
#   ./Tools/scroll-lab.sh run [options]        measures, writes report.md, exits 1 on a broken invariant
#       --builds <ref,label=ref,...>           default HEAD; each one is built first if it is not yet
#       --repeat <n>                           default 3, interleaved so every build sees the same machine
#       --sizes <WxH,...>                      default 1440x900,1100x800
#       --scenarios <name,...>                 default all; see `plan` in Tools/scroll-lab.py
#       --out <dir>
#   ./Tools/scroll-lab.sh report <dir>         reads the traces of an earlier run again
#   ./Tools/scroll-lab.sh profile <ref> <scenario> <corpus> [WxH] [step]
#                                              one scenario again, with `sample` from its step (default up)
#                                              for SCROLL_LAB_SAMPLE_SECONDS (default 30)
#
# **Nothing here is seen and nothing takes focus.** Each run is `open -g -n -W` on a bundle with its
# own identifier (`be.spatie.bloom.scroll-lab`), `LSUIElement` set, and a database of its own named
# through `BLOOM_DB_PATH`. The window is transparent and ignores the mouse; see `ScrollLab.swift`.
# The owner's app, data and preferences domain are never named.
#
# **A revision from before this file existed is measured too.** `build` exports the revision with
# `git archive`, copies this checkout's `ScrollLab.swift` into it and adds the one line that starts
# it, so the same driver runs inside every build being compared. Revisions from before
# `BloomLauncher` existed get a launcher of their own.
#
# **Several runs may go at once.** Each takes the first free lane, a copy of the app with a bundle
# identifier of its own, so no run wipes the preferences of another; builds of one commit queue
# behind a lock. Frame timings from parallel runs share the machine, so compare builds inside one run.
#
# Builds compile with `nice` and one at a time: this Mac is somebody's workstation. Set
# SCROLL_LAB_HOME to keep builds and runs somewhere other than the temporary directory, and
# SCROLL_LAB_CONFIGURATION=debug for a quicker build that measures nothing about smoothness.
set -euo pipefail
zmodload zsh/system
cd "$(dirname "$0")/.."
repo="$PWD"
lab_home="${SCROLL_LAB_HOME:-${TMPDIR:-/tmp}/bloom-scroll-lab}"
configuration="${SCROLL_LAB_CONFIGURATION:-release}"
bundle_id="be.spatie.bloom.scroll-lab"
max_lanes=8
lane=""
# A cap on a run that never ends, not a measurement: the longest plan takes a few minutes.
run_ceiling_seconds=1800

say() { print -ru2 -- "scroll lab: $*" }

commit_of() { git -C "$repo" rev-parse --short=10 "$1^{commit}" }

app_path() { print -r -- "$lab_home/apps/$1-$configuration/Bloom Scroll Lab.app" }

lane_app_path() { print -r -- "$lab_home/apps/$1-$configuration-lane$lane/Bloom Scroll Lab.app" }

# Held until this script exits, which is what frees the lane for the next run.
claim_lane() {
  mkdir -p "$lab_home"
  local candidate lock
  for candidate in {1..$max_lanes}; do
    lock="$lab_home/lane-$candidate.lock"
    touch "$lock"
    if zsystem flock -t 0 "$lock" 2>/dev/null; then
      lane=$candidate
      bundle_id="be.spatie.bloom.scroll-lab.lane$lane"
      say "lane $lane"
      return
    fi
  done
  say "all $max_lanes lanes are busy"
  return 1
}

# The commit's app under this lane's bundle identifier.
lane_copy() {
  local base app
  base="$(app_path "$1")"
  app="$(lane_app_path "$1")"
  rm -rf "$app"
  mkdir -p "${app:h}"
  ditto "$base" "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
}

# The running binary as `pgrep -f` sees it. LaunchServices starts it from its real path, under
# /private and without the doubled slash TMPDIR leaves, so the pattern starts at the lab's own part.
process_pattern() { print -r -- "bloom-scroll-lab/apps/${1:h:t}/Bloom Scroll Lab.app/Contents/MacOS/Bloom" }

inject() {
  local source="$1"
  cp "$repo/Sources/Bloom/Design/ScrollLab.swift" "$source/Sources/Bloom/Design/ScrollLab.swift"
  local launcher="$source/Sources/Bloom/BloomLauncher.swift"
  if [[ -f "$launcher" ]]; then
    grep -q "ScrollLab.isRequested" "$launcher" && return
    python3 -I - "$launcher" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
marker = "static func main() async {\n"
assert marker in text, "BloomLauncher.main not found"
path.write_text(text.replace(marker, marker + "        if ScrollLab.isRequested { ScrollLab.runAndExit() }\n", 1))
PY
  else
    sed -i '' 's/^@main$//' "$source/Sources/Bloom/BloomApp.swift"
    cat > "$source/Sources/Bloom/ScrollLabLauncher.swift" <<'SWIFT'
import SwiftUI

@main
enum ScrollLabLauncher {
    @MainActor
    static func main() {
        if ScrollLab.isRequested { ScrollLab.runAndExit() }
        BloomApp.main()
    }
}
SWIFT
  fi
}

build_one() {
  local commit app source log lock lock_fd
  commit="$(commit_of "$1")"
  app="$(app_path "$commit")"
  mkdir -p "$lab_home/src"
  lock="$lab_home/src/$commit.lock"
  touch "$lock"
  zsystem flock -f lock_fd "$lock"
  {
    build_unlocked "$commit" "$app"
  } always {
    zsystem flock -u $lock_fd
  }
}

build_unlocked() {
  local commit="$1" app="$2" source log
  if [[ -x "$app/Contents/MacOS/Bloom" && "$app/Contents/MacOS/Bloom" -nt "$repo/Sources/Bloom/Design/ScrollLab.swift" ]]; then
    say "build $commit is cached"
    return
  fi
  source="$lab_home/src/$commit"
  log="$lab_home/src/$commit.log"
  mkdir -p "$source"
  if [[ ! -f "$source/Package.swift" ]]; then
    git -C "$repo" archive "$commit" | tar -x -C "$source"
  fi
  inject "$source"
  say "building $commit ($configuration), log in $log"
  (cd "$source" && nice -n 15 swift build -c "$configuration" --product Bloom >"$log" 2>&1) || {
    tail -30 "$log" >&2
    say "build of $commit failed"
    return 1
  }
  bundle "$source" "$app"
  say "built $app"
}

bundle() {
  local source="$1" app="$2" bin framework
  bin="$(cd "$source" && swift build -c "$configuration" --show-bin-path)"
  framework="$(find "$source/.build/artifacts" -path '*Sparkle.xcframework/macos*/Sparkle.framework' -type d | head -1)"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$bin/Bloom" "$app/Contents/MacOS/Bloom"
  cp "$source/Resources/Info.plist" "$app/Contents/Info.plist"
  ditto "$source/Resources" "$app/Contents/Resources"
  [[ -n "$framework" ]] && ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
  local plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Bloom Scroll Lab" "$plist"
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$plist"
  /usr/libexec/PlistBuddy -c "Add :NSAppSleepDisabled bool true" "$plist" 2>/dev/null || true
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/Bloom" 2>/dev/null || true
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
}

# Everything the previous run may have left in the lab's own domain, so no run inherits a column
# width or a text size from the one before it.
fresh_defaults() {
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/$bundle_id.savedState"
  defaults write "$bundle_id" installPing.isEnabled -bool false
  defaults write "$bundle_id" mailpit.enabled -bool false
  defaults write "$bundle_id" NSAppSleepDisabled -bool true
}

launch() {
  local app="$1" directory="$2" plan="$3" started=$SECONDS
  fresh_defaults
  open -g -n -W -a "$app" --env BLOOM_DB_PATH="$directory/bloom.sqlite" \
    --stdout "$directory/stdout.log" --stderr "$directory/stderr.log" \
    --args --scroll-lab "$directory/trace.ndjson" --scroll-lab-plan "$plan" &
  local waiter=$!
  while kill -0 "$waiter" 2>/dev/null; do
    if (( SECONDS - started > run_ceiling_seconds )); then
      say "run in $directory passed $run_ceiling_seconds s; stopping it"
      pkill -f "$(process_pattern "$app")" || true
      break
    fi
    sleep 2
  done
  wait "$waiter" 2>/dev/null || true
  print -r -- $(( SECONDS - started ))
}

run() {
  local builds="HEAD" repeat=3 sizes="1440x900,1100x800" scenarios="" out=""
  while (( $# )); do
    case "$1" in
      --builds) builds="$2"; shift 2 ;;
      --repeat) repeat="$2"; shift 2 ;;
      --sizes) sizes="$2"; shift 2 ;;
      --scenarios) scenarios="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) say "unknown option $1"; return 2 ;;
    esac
  done
  out="${out:-$lab_home/runs/$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$out"
  local -a refs labels commits size_list
  for entry in "${(@s:,:)builds}"; do
    labels+=("${entry%%=*}")
    refs+=("${entry#*=}")
  done
  size_list=("${(@s:,:)sizes}")
  # Resolved once, before building: a commit made meanwhile must not move what HEAD names.
  for ref in "${refs[@]}"; do commits+=("$(commit_of "$ref")"); done
  for commit in "${commits[@]}"; do build_one "$commit"; done
  local commit label directory seconds load
  claim_lane
  for commit in "${commits[@]}"; do lane_copy "$commit"; done
  python3 -I "$repo/Tools/scroll-lab.py" seed "$out/corpus" >/dev/null
  local scenario_args=("${(@s:,:)scenarios}")
  for size in "${size_list[@]}"; do
    python3 -I "$repo/Tools/scroll-lab.py" plan "$out/corpus/corpus.json" "$out/plan-$size.json" "$size" \
      ${scenarios:+"${scenario_args[@]}"} >/dev/null
  done
  for (( pass = 1; pass <= repeat; pass++ )); do
    for size in "${size_list[@]}"; do
      for index in {1..${#commits}}; do
        commit="${commits[$index]}" label="${labels[$index]}"
        directory="$out/$commit-$size-$pass"
        mkdir -p "$directory"
        cp "$out/corpus/bloom.sqlite" "$directory/bloom.sqlite"
        say "pass $pass/$repeat, $size, $label ($commit)"
        load="$(LC_ALL=C sysctl -n vm.loadavg | awk '{print $2}' | tr , .)"
        seconds="$(launch "$(lane_app_path "$commit")" "$directory" "$out/plan-$size.json")"
        mv "$directory/trace.ndjson" "$directory/run.ndjson" 2>/dev/null || say "no trace in $directory"
        print -r -- "{\"build\": \"$label\", \"commit\": \"$commit\", \"size\": \"$size\", \"pass\": $pass, \"seconds\": $seconds, \"loadBefore\": $load}" \
          > "$directory/run.meta.json"
        rm -f "$directory/bloom.sqlite"*
      done
    done
  done
  python3 -I "$repo/Tools/scroll-lab.py" report "$out"
}

# **Profile the worst run rather than guess at it.** `sample` is attached to the lab's own process
# for the length of the upward gesture, which is found by the step line the lab prints as it
# starts it, so the profile holds the gesture and none of the launch.
profile() {
  local ref="$1" scenario="$2" corpus="$3" size="${4:-1440x900}" phase="${5:-up}" commit out pid
  commit="$(commit_of "$ref")"
  build_one "$commit"
  claim_lane
  lane_copy "$commit"
  out="$lab_home/profiles/$commit-$scenario-$corpus-$phase-$(date +%H%M%S)-lane$lane"
  mkdir -p "$out/run"
  python3 -I "$repo/Tools/scroll-lab.py" seed "$out/corpus" >/dev/null
  python3 -I "$repo/Tools/scroll-lab.py" plan "$out/corpus/corpus.json" "$out/plan.json" "$size" "$scenario" >/dev/null
  python3 -I - "$out/plan.json" "$scenario/$corpus/" <<'PY'
import json, sys
path, prefix = sys.argv[1], sys.argv[2]
plan = json.load(open(path))
plan["steps"] = [step for step in plan["steps"] if step["label"].startswith(prefix)]
json.dump(plan, open(path, "w"))
PY
  cp "$out/corpus/bloom.sqlite" "$out/run/bloom.sqlite"
  launch "$(lane_app_path "$commit")" "$out/run" "$out/plan.json" >/dev/null &
  local launched=$!
  for _ in {1..600}; do
    grep -q "$scenario/$corpus/$phase" "$out/run/stderr.log" 2>/dev/null && break
    sleep 0.5
  done
  pid="$(pgrep -f "$(process_pattern "$(lane_app_path "$commit")")" | head -1)"
  if [[ -n "$pid" ]]; then
    sample "$pid" "${SCROLL_LAB_SAMPLE_SECONDS:-30}" -file "$out/sample.txt" >/dev/null 2>&1 || say "sample failed on $pid"
  else
    say "the lab process was not found; nothing sampled"
  fi
  wait "$launched" || true
  say "profile in $out/sample.txt"
}

command="${1:-help}"
shift || true
case "$command" in
  build) for ref in "$@"; do build_one "$ref"; done ;;
  run) run "$@" ;;
  report) python3 -I "$repo/Tools/scroll-lab.py" report "$1" ;;
  profile) profile "$@" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
