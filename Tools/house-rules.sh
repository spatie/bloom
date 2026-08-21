#!/bin/bash
# The conventions this repository has that no off the shelf linter knows about.
#
#   ./Tools/house-rules.sh
#
# Three rules, and every one of them is here because it has already been broken:
#
#   1. No em dashes and no en dashes. Anywhere. They arrive by the hundred from
#      anything that writes prose for you, and once one is in a file the next
#      writer copies the house style it thinks it sees.
#   2. The app is Bloom. It was called Baton until it was renamed, and the old
#      name still turns up in new text written from stale memory.
#   3. British spelling. The tree is already at 69 greys to 1 gray and 74
#      cancelleds to 1 canceled, so this is about keeping it that way.
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

# The two characters this file is not allowed to contain, since it is scanned by
# the rule it implements. Built from their UTF-8 bytes instead.
em_dash="$(printf '\342\200\224')"
en_dash="$(printf '\342\200\223')"

echo "==> no em dashes or en dashes"
# .claude holds agent skills written elsewhere and vendored in as they are, and
# Tests/fixtures holds recorded sessions that have to stay byte for byte what
# the agent actually emitted. Neither is house prose and neither may be rewritten.
if hits="$(git grep -n -I -e "$em_dash" -e "$en_dash" -- ':!.claude' ':!Tests/fixtures' || true)" && [ -n "$hits" ]; then
  echo "$hits" | while IFS= read -r line; do echo "  $line"; done
  report "A dash that should be a comma, a full stop or a pair of brackets."
fi

echo "==> the app is called Bloom"
# This file is exempt from the two rules below because it has to spell out what
# it is looking for. The dash rule above does apply to it, which is why the two
# characters are built from their bytes rather than typed.
# This file is exempt from this rule and the spelling rule below, because it has
# to spell out what it is looking for. The dash rule above does apply to it,
# which is why those two characters are built from their bytes rather than typed.
#
# Every file that is allowed to say Baton, and why. This list should only ever
# get shorter. A file not on it that mentions the old name is a new mistake.
baton_allowed=(
  'docs/PROTOCOL.md'                                    # quotes a recorded session
  'Tools/build.sh'                                      # BATON_CODESIGN_IDENTITY, kept working on purpose
  'Tests/fixtures/'                                     # recorded sessions, byte for byte
  'Sources/BloomCore/LegacyDatabase.swift'              # reads the old app's database
  'Sources/BloomCore/LegacyDefaults.swift'              # reads the old app's preferences
  'Sources/BloomCore/WorkspaceManager.swift'            # a comment about the old worktree home
  'Tests/BloomCoreTests/AgentEventTests.swift'          # sample paths and recorded payloads
  'Tests/BloomCoreTests/FilePathGuessTests.swift'       # sample paths
  'Tests/BloomCoreTests/HomeListTests.swift'            # a sample repository name
  'Tests/BloomCoreTests/InstallPingTests.swift'         # a sample path
  'Tests/BloomCoreTests/LegacyMigrationTests.swift'     # tests the migration off the old name
  'Tests/BloomCoreTests/RepositoryStartPlanTests.swift' # sample folder names
  'Tools/icon/lib9.py'                                  # a sample path
)
for file in $(git grep -l -I -i baton -- ':!.claude' ':!Tools/house-rules.sh' || true); do
  allowed=0
  for prefix in "${baton_allowed[@]}"; do
    case "$file" in "$prefix"*) allowed=1 ;; esac
  done
  if [ "$allowed" -eq 0 ]; then
    git grep -n -I -i baton -- "$file" | while IFS= read -r line; do echo "  $line"; done
    report "$file calls the app by its old name."
  fi
done
# Not a finding, just housekeeping: an exception nobody needs any more.
for prefix in "${baton_allowed[@]}"; do
  case "$prefix" in */) continue ;; esac
  if [ -f "$prefix" ] && ! git grep -q -I -i baton -- "$prefix"; then
    echo "  note: $prefix no longer says Baton, so it can come off the list in $0."
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
  if hits="$(git grep -n -I -i -w "$word" -- ':!.claude' ':!Tests/fixtures' ':!Tools/house-rules.sh' || true)" && [ -n "$hits" ]; then
    echo "$hits" | while IFS= read -r line; do echo "  $line"; done
    report "American spelling: $word."
  fi
done
for word in "${american_in_prose[@]}"; do
  if hits="$(git grep -n -I -i -w "$word" -- '*.md' ':!.claude' ':!Tools/house-rules.sh' || true)" && [ -n "$hits" ]; then
    echo "$hits" | while IFS= read -r line; do echo "  $line"; done
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
