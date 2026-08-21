#!/bin/bash
# The conventions this repository has that no off the shelf linter knows about.
#
#   ./Tools/house-rules.sh
#
# Five rules, and every one of them is here because it has already been broken:
#
#   1. No em dashes and no en dashes. Anywhere. They arrive by the hundred from
#      anything that writes prose for you, and once one is in a file the next
#      writer copies the house style it thinks it sees.
#   2. The app is Bloom. It was called Baton until it was renamed, and the old
#      name still turns up in new text written from stale memory.
#   3. British spelling. The tree is already at 69 greys to 1 gray and 74
#      cancelleds to 1 canceled, so this is about keeping it that way.
#   4. BloomCore never imports SwiftUI. CLAUDE.md has said so since the split
#      was made and nothing checked it, which is the state every rule here was
#      in the day before it was written.
#   5. One way to start a workspace. Four routes each grew their own half of it
#      once already; see the rule itself for what that cost.
#
# Exit status is 1 if anything was found, and every finding is printed with the
# file and line so it can be opened. The word lists are deliberately narrow:
# a rule that cries wolf gets switched off, so anything with a legitimate use in
# this codebase either stays out of the list or is named in an exception below.

set -euo pipefail
cd "$(dirname "$0")/.."

findings=0

report() {
  findings=$((findings + 1))
  echo "$1"
}

# One line per hit, cut short. A recorded fixture is one line of several
# kilobytes, and the file and line number are the part you need anyway.
show() {
  while IFS= read -r line; do echo "  ${line:0:160}"; done
}

# The two characters this file is not allowed to contain, since it is scanned by
# the rule it implements. Built from their UTF-8 bytes instead.
em_dash="$(printf '\342\200\224')"
en_dash="$(printf '\342\200\223')"

echo "==> no em dashes or en dashes"
# .claude holds agent skills written elsewhere and vendored in as they are, and
# the fixtures hold recorded sessions that have to stay byte for byte what the
# agent actually emitted. Neither is house prose and neither may be rewritten.
# The fixtures are matched wherever they sit, because they are being moved.
if hits="$(git grep -n -I -e "$em_dash" -e "$en_dash" -- ':!.claude' ':!*fixtures/*' || true)" && [ -n "$hits" ]; then
  echo "$hits" | show
  report "A dash that should be a comma, a full stop or a pair of brackets."
fi

echo "==> the app is called Bloom"
# This file is exempt from this rule and the spelling rule below, because it has
# to spell out what it is looking for. The dash rule above does apply to it,
# which is why those two characters are built from their bytes rather than typed.
#
# Every file that is allowed to say Baton, and why. This list should only ever
# get shorter. A file not on it that mentions the old name is a new mistake.
baton_allowed=(
  '*PROTOCOL.md'                                    # quotes a recorded session
  '*build.sh'                                       # BATON_CODESIGN_IDENTITY, kept working on purpose
  '*fixtures/'                                      # recorded sessions, byte for byte
  'Sources/BloomCore/LegacyDatabase.swift'          # reads the old app's database
  'Sources/BloomCore/LegacyDefaults.swift'          # reads the old app's preferences
  'Sources/BloomCore/WorkspaceManager.swift'        # a comment about the old worktree home
  'Tests/BloomCoreTests/AgentEventTests.swift'      # sample paths and recorded payloads
  'Tests/BloomCoreTests/FilePathGuessTests.swift'   # sample paths
  'Tests/BloomCoreTests/HomeListTests.swift'        # a sample repository name
  'Tests/BloomCoreTests/InstallPingTests.swift'     # a sample path
  'Tests/BloomCoreTests/LegacyMigrationTests.swift' # tests the migration off the old name
  'Tests/BloomCoreTests/RepositoryStartPlanTests.swift' # sample folder names
  'Tools/icon/lib9.py'                              # a sample path
)
for file in $(git grep -l -I -i baton -- ':!.claude' ':!Tools/house-rules.sh' || true); do
  allowed=0
  for prefix in "${baton_allowed[@]}"; do
    # Unquoted on purpose, so an entry can be a pattern. A file is being moved
    # under this list's feet and none of these paths contain a space.
    # shellcheck disable=SC2254
    case "$file" in $prefix*) allowed=1 ;; esac
  done
  if [ "$allowed" -eq 0 ]; then
    git grep -n -I -i baton -- "$file" | show
    report "$file calls the app by its old name."
  fi
done
# Not a finding, just housekeeping: an exception nobody needs any more.
for prefix in "${baton_allowed[@]}"; do
  case "$prefix" in */|*'*'*) continue ;; esac
  if [ -f "$prefix" ] && ! git grep -q -I -i baton -- "$prefix"; then
    echo "  note: $prefix no longer says Baton, so it can come off the list in $0."
  fi
done

echo "==> the core does not import SwiftUI"
# The split only means anything while it holds. Everything in BloomCore is
# reachable by the test target and everything in Sources/Bloom is not, so a
# decision that drifts into a view is a decision nothing can test. One import is
# how that starts.
if hits="$(git grep -n -I -e 'import SwiftUI' -e 'import AppKit' -- 'Sources/BloomCore/*' || true)" && [ -n "$hits" ]; then
  echo "$hits" | show
  report "BloomCore imports a UI framework. Move the view part into Sources/Bloom and leave the decision here, where the suite can reach it."
fi

echo "==> one way to start a workspace"
# `WorkspaceManager.createWorkspace` cuts a worktree and writes a row. It does
# not open the chat, write the model and effort onto it, run the setup script,
# name the workspace or record who asked for it. All of that is
# `WorkspaceManager.start`, and it is one method because it used to be four
# half-copies: the create sheet had the lot, the `bloom://` link and the
# Services menu had none of it and were silently hardwired to the defaults, and
# the Shortcuts intent could not reach any of it, so it fired a URL and then
# read the database every 400ms for a minute hoping to recognise its own row.
#
# The compiler holds most of this line, because `createWorkspace` is internal to
# BloomCore and the app target cannot call it at all. What is left is a new file
# inside the core, which the compiler would allow and which is exactly how the
# next half-copy would start.
#
# Every file inside the core allowed to name it, and why. This list should only
# ever get shorter. A file not on it that names it is a new mistake.
#
# The suite is not on it and does not need to be: it reaches the method through
# `@testable`, and a test that wants a worktree and nothing else is not a route
# into the app.
create_workspace_allowed=(
  'Sources/BloomCore/WorkspaceManager.swift' # declares it
  'Sources/BloomCore/WorkspaceStart.swift'   # the one caller: `start`
)
for file in $(git grep -l -I -e 'createWorkspace(' -- 'Sources/BloomCore/*' || true); do
  allowed=0
  for path in "${create_workspace_allowed[@]}"; do
    [ "$file" = "$path" ] && allowed=1
  done
  if [ "$allowed" -eq 0 ]; then
    git grep -n -I -e 'createWorkspace(' -- "$file" | show
    report "$file cuts a worktree itself instead of calling WorkspaceManager.start. A route that stops at createWorkspace gets no chat, no setup run, no name and no record of who asked, and nothing says so."
  fi
done

echo "==> British spelling"
# Words with an American spelling that has no other job in this codebase.
# Deliberately absent: colour, behaviour, centre, dialogue, catalogue and
# licence, because Apple's own API is spelled the American way and the tree is
# full of foregroundColor, scrollBehavior and NSTextAlignment.center.
american=(defense offense fulfill fulfillment skeptical acknowledgment maneuver
          labeled modeled traveled centered analyze analyzing paralyze
          enrollment installment)
# These three do have a job in code today: "Favorites" names a Finder sidebar
# section, ToolRefusal parses the literal string "canceled" out of agent output,
# and gray names a CoreGraphics colour space. In prose there is no such excuse.
american_in_prose=(favorite favorites gray canceled)

for word in "${american[@]}"; do
  if hits="$(git grep -n -I -i -w "$word" -- ':!.claude' ':!*fixtures/*' ':!Tools/house-rules.sh' || true)" && [ -n "$hits" ]; then
    echo "$hits" | show
    report "American spelling: $word."
  fi
done
for word in "${american_in_prose[@]}"; do
  if hits="$(git grep -n -I -i -w "$word" -- '*.md' ':!.claude' ':!Tools/house-rules.sh' || true)" && [ -n "$hits" ]; then
    echo "$hits" | show
    report "American spelling in prose: $word."
  fi
done

if [ "$findings" -gt 0 ]; then
  echo
  echo "$findings house rule violations."
  exit 1
fi
echo
echo "House rules pass."
