#!/bin/bash
# The conventions this repository has that no off the shelf linter knows about.
#
#   ./Tools/house-rules.sh
#
# Seven rules, and every one of them is here because it has already been broken:
#
#   1. No em dashes and no en dashes. Anywhere. They arrive by the hundred from
#      anything that writes prose for you, and once one is in a file the next
#      writer copies the house style it thinks it sees.
#   2. The app is Bloom. It was called Baton until it was renamed, and the old
#      name still turns up in new text written from stale memory.
#   3. British spelling. The tree is already at 69 greys to 1 gray and 74
#      cancelleds to 1 canceled, so this is about keeping it that way.
#   4. Only the app target imports a UI framework. CLAUDE.md has said so since
#      the split was made and nothing checked it, which is the state every rule
#      here was in the day before it was written.
#   5. One way to start a workspace. Four routes each grew their own half of it
#      once already; see the rule itself for what that cost.
#   6. One way to move a state. The three columns that describe what a workspace
#      or a chat IS are only movable through the lifecycle that also does the
#      work the move implies; see the rule itself.
#   7. An id has a type. Every id was a bare String until they were not, and a
#      new one declared that way puts the hole back without the compiler having
#      anything to say about it.
#
# Exit status is 1 if anything was found, and every finding is printed with the
# file and line so it can be opened. The word lists are deliberately narrow:
# a rule that cries wolf gets switched off, so anything with a legitimate use in
# this codebase either stays out of the list or is named in an exception below.
#
# **Every search here passes `--untracked`, and that is load bearing.** Six of
# these seven rules did not, and a plain `git grep` sees only what is tracked, so
# a brand new file was invisible to all six until somebody staged it. One decoy
# file inside `Sources/BloomCore` carrying a violation of each raised one finding
# untracked and six the moment it was added, on identical bytes. That is worst
# exactly where it matters: rules 4, 5 and 6 say in their own comments that the
# compiler holds everything EXCEPT a new file inside the core, and a new file is
# untracked until it is staged, so `make lint` passed on precisely the thing the
# rule exists to catch. `--untracked` does not include ignored files, so `.build`
# and the rest of .gitignore stay out.

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
if hits="$(git grep --untracked -n -I -e "$em_dash" -e "$en_dash" -- ':!.claude' ':!*fixtures/*' || true)" && [ -n "$hits" ]; then
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
for file in $(git grep --untracked -l -I -i baton -- ':!.claude' ':!Tools/house-rules.sh' || true); do
  allowed=0
  for prefix in "${baton_allowed[@]}"; do
    # Unquoted on purpose, so an entry can be a pattern. A file is being moved
    # under this list's feet and none of these paths contain a space.
    # shellcheck disable=SC2254
    case "$file" in $prefix*) allowed=1 ;; esac
  done
  if [ "$allowed" -eq 0 ]; then
    git grep --untracked -n -I -i baton -- "$file" | show
    report "$file calls the app by its old name."
  fi
done
# Not a finding, just housekeeping: an exception nobody needs any more.
for prefix in "${baton_allowed[@]}"; do
  case "$prefix" in */|*'*'*) continue ;; esac
  if [ -f "$prefix" ] && ! git grep --untracked -q -I -i baton -- "$prefix"; then
    echo "  note: $prefix no longer says Baton, so it can come off the list in $0."
  fi
done

echo "==> only the app target imports a UI framework"
# The split only means anything while it holds. Everything in BloomCore is
# reachable by the test target and everything in Sources/Bloom is not, so a
# decision that drifts into a view is a decision nothing can test. One import is
# how that starts. `bloom-bridge` is scanned for the same reason and one more: it
# is a stdio relay a CLI launches as a child process, and it has no user
# interface to put a window in.
#
# Two spellings got past the two literals this used to look for, and both were
# compiled to check rather than reasoned about. `import Cocoa` brings NSView in
# by re-export, so a core file could have the whole of AppKit without naming it.
# `import class AppKit.NSView` names AppKit and does not contain the string
# "import AppKit", because the declaration kind sits between the two words. So
# this matches the framework after `import` and an optional declaration kind,
# whatever is in front of them, which also covers `@_exported import AppKit` and
# `@preconcurrency import SwiftUI`.
#
# SwiftTerm and Sparkle are in the same sentence in CLAUDE.md and deliberately
# not here. Only the app target declares them in `Package.swift`, so an import
# of either from the core or the bridge is a link error rather than a lint
# finding, and a rule that can never fire is a rule that gets believed in.
ui_import='(^|[^A-Za-z0-9_])import[[:space:]]+([a-z]+[[:space:]]+)?(SwiftUI|AppKit|Cocoa)([^A-Za-z0-9_]|$)'
if hits="$(git grep --untracked -n -I -E "$ui_import" -- 'Sources/BloomCore/*' 'Sources/bloom-bridge/*' || true)" && [ -n "$hits" ]; then
  echo "$hits" | show
  report "A target that is not Sources/Bloom imports a UI framework. Move the view part into Sources/Bloom and leave the decision behind, where the suite can reach it."
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
for file in $(git grep --untracked -l -I -e 'createWorkspace(' -- 'Sources/BloomCore/*' || true); do
  allowed=0
  for path in "${create_workspace_allowed[@]}"; do
    [ "$file" = "$path" ] && allowed=1
  done
  if [ "$allowed" -eq 0 ]; then
    git grep --untracked -n -I -e 'createWorkspace(' -- "$file" | show
    report "$file cuts a worktree itself instead of calling WorkspaceManager.start. A route that stops at createWorkspace gets no chat, no setup run, no name and no record of who asked, and nothing says so."
  fi
done

echo "==> a state moves through its lifecycle"
# `Workspace.state`, `Workspace.setupState` and `Session.state` say what a thing
# IS, and setting one of them is never the whole of changing it. Archiving is
# removing the worktree and then saying so; a row that said a workspace was live
# after its worktree had gone is in CLAUDE.md and it does not heal. Filing a
# setup run is writing the state and the log together; `.failed` with nothing to
# read is a half-truth the next reader treats as whole, and a restored workspace
# went on saying `succeeded` about a directory deleted months earlier. So each of
# those three columns has one owner that takes an EVENT and does the whole job:
# `SetupLifecycle`, `SessionLifecycle`, `WorkspaceLifecycle`.
#
# The compiler holds most of this line. All three are `public internal(set)`, so
# nothing in `Sources/Bloom` can assign one at all, however it reaches the value:
# through `Store.update`'s closure, through a copy of a row, anywhere. What is
# left is a new file inside the core, which the compiler would allow and which is
# exactly how a fourth writer would start, so that is all this looks at.
#
# It matches an assignment of a NAMED case, which is how a half-done transition
# is actually written, with or without a receiver in front of it: a new file
# extending `Workspace` can write `setupState = .succeeded` with no dot at all.
# Carrying a state the lifecycle already produced from one copy of a row to
# another (`$0.state = session.state` in the two runners) is not that and is not
# matched: those two lines mirror a value the table decided.
#
# Every file inside the core allowed to name one, and why. This list should only
# ever get shorter. A file not on it that names one is a new mistake.
#
# The suite is not on it and does not need to be: `@testable` reaches these, and
# a fixture stating what a row looked like is not a route into the app.
# One entry, and the other two lifecycles are absent because they do not need to
# be: `SetupLifecycle` and `SessionLifecycle` write the destination the table
# handed them rather than a case they named, so there is nothing here for this to
# see. If one of them ever starts naming a case, that is worth reading before it
# is worth allowing.
state_move_allowed=(
  'Sources/BloomCore/WorkspaceLifecycle.swift' # archive() and restore(), which name both
)
state_move='(^|[^A-Za-z0-9_])(state|setupState) *= *\.(active|archived|pending|running|succeeded|failed|skipped|idle|waiting|cancelled)([^A-Za-z0-9_]|$)'
for file in $(git grep --untracked -l -I -E "$state_move" -- 'Sources/BloomCore/*' || true); do
  allowed=0
  for path in "${state_move_allowed[@]}"; do
    [ "$file" = "$path" ] && allowed=1
  done
  if [ "$allowed" -eq 0 ]; then
    git grep --untracked -n -I -E "$state_move" -- "$file" | show
    report "$file sets a lifecycle state directly instead of applying an event. A state written on its own is a state without the work that makes it true: an archive that removed nothing, or an outcome with no log under it. Use apply(), archive() or restore()."
  fi
done
# Not a finding, just housekeeping: an exception nobody needs any more.
for path in "${state_move_allowed[@]}"; do
  if [ -f "$path" ] && ! git grep --untracked -q -I -E "$state_move" -- "$path"; then
    echo "  note: $path no longer moves a state, so it can come off the list in $0."
  fi
done

echo "==> an id has a type"
# Every id in Bloom used to be a bare `String`, so `store.update(workspaceID:
# session.id)` compiled, ran, and updated no row at all. There is no crash and
# no log line for that, just a workspace that did not archive. `RepoID`,
# `WorkspaceID`, `SessionID`, `TerminalTabID`, `ReviewCommentID` and
# `PermissionGrantID` are what stopped it, and the compiler holds the line
# everywhere they are used.
#
# What the compiler cannot object to is a NEW property declared `var
# somethingID: String`, because a String is a perfectly good String. That one
# declaration reopens the hole quietly, and everything downstream of it goes
# back to being interchangeable. So this rule is about declarations, not usage:
# usage is already unrepresentable and needs no rule.
#
# Only stored properties are looked at. A computed `var id: String { path }` is
# an `Identifiable` conformance derived from something else and identifies no
# row, which is why `ChangedFileTree`, `SlashCommand` and a dozen others are not
# in the lists below and do not need to be.
#
# Two vocabularies are exempt wholesale, and both for the same reason: they are
# not Bloom's words. `AgentEvent` is Claude Code's stream-json and `CodexEvent`
# is the Codex app-server protocol, and every id in them (`uuid`, `toolUseID`,
# `threadID`, the CLI's own `sessionID`) is an opaque token Bloom receives,
# stores and hands back without ever looking inside. Typing those would mean a
# wrapper at every parse site and would buy nothing, because there is no second
# kind of thread id to confuse one with.
id_type_allowed_files=(
  'Sources/BloomCore/AgentEvent.swift'   # Claude Code's stream-json, as measured
  'Sources/BloomCore/CodexEvent.swift'   # the Codex app-server protocol
  'Sources/BloomCore/CodexClient.swift'  # the same protocol's request envelopes
)
# Names that are never a Bloom row, wherever they appear. This list should only
# ever get shorter. A name not on it is a new mistake.
id_type_allowed_names=(
  agentSessionID    # the CLI's session, not Bloom's. Different value, different lifetime
  spawnToolUseID    # a tool_use id out of a payload
  toolUseID         # the same
  parentToolUseID   # the same
  refID             # a stored tool_use id, so a result can find its call
  requestID         # the CLI's permission request
  messageID         # the CLI's message
  uuid              # the CLI's row identity
  threadID          # Codex's thread
  turnID            # Codex's turn
  itemID            # Codex's item
  clientID          # Codex's client
  processID         # a pid, as text
  bundleID          # macOS, not Bloom
  ownerID           # a split pane, which is the layout's namespace and not a row
)
# The remaining stored `String` ids, each one a deliberate decision. This list
# should only ever get shorter.
id_type_allowed_lines=(
  'Sources/BloomCore/HomeList.swift'                  # a date bucket key, not a row
  'Sources/BloomCore/Settings.swift'                  # a run script named in settings
  'Sources/BloomCore/CodexModelCatalog.swift'         # a model name the CLI offers
  'Sources/BloomCore/EditorCatalog.swift'             # an application, by bundle id
  'Sources/Bloom/Views/Center/ComposerOption.swift'   # a picker entry, "opus" and friends
  'Sources/Bloom/Views/Center/CenterTab.swift'        # a tab: a terminal row, a browser or the review pane
  'Sources/BloomCore/TerminalPaneCensus.swift'        # the same tab id, read back off the same bytes
  'Sources/Bloom/Views/Center/PromptAttachment.swift' # a draft key, which has no session yet
  'Sources/Bloom/State/TranscriptModel.swift'         # payload ids, read straight off an event
)
# A stored property whose name ends in ID or Ids and whose type is a bare
# String. Trailing `{` is excluded by the `$` anchor, which is what leaves
# computed properties out.
# The pathspec keeps this one to `Sources/`, and .gitignore keeps `.build` out.
id_declaration='^[[:space:]]*(public |private |internal |fileprivate )?(var|let) [A-Za-z_]*([iI][dD]|IDs)[[:space:]]*:[[:space:]]*(String|String\?|\[String\]|Set<String>)[[:space:]]*(=[^{]*)?$'
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"
  allowed=0
  for path in "${id_type_allowed_files[@]}" "${id_type_allowed_lines[@]}"; do
    [ "$file" = "$path" ] && allowed=1
  done
  for name in "${id_type_allowed_names[@]}"; do
    case "$hit" in *" $name:"*|*" $name "*) allowed=1 ;; esac
  done
  if [ "$allowed" -eq 0 ]; then
    echo "$hit" | show
    report "$file declares an id as a bare String. Give it a type from Sources/BloomCore/Identifier.swift, or add it to the list in $0 saying which id from outside Bloom it holds. A String id can be handed to any lookup that wants any other id, and the write that lands on no row says nothing at all."
  fi
done <<EOF
$(git grep --untracked -n -I -E "$id_declaration" -- 'Sources/*' || true)
EOF

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
  if hits="$(git grep --untracked -n -I -i -w "$word" -- ':!.claude' ':!*fixtures/*' ':!Tools/house-rules.sh' || true)" && [ -n "$hits" ]; then
    echo "$hits" | show
    report "American spelling: $word."
  fi
done
for word in "${american_in_prose[@]}"; do
  if hits="$(git grep --untracked -n -I -i -w "$word" -- '*.md' ':!.claude' ':!Tools/house-rules.sh' || true)" && [ -n "$hits" ]; then
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
