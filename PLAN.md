# Baton

A Swift/SwiftUI rebuild of Conductor: parallel Claude Code agents, one git worktree each.

## Status

Every phase below is done and checked against its endgoal. The app builds with zero warnings,
188 core tests pass, and the whole loop has been driven end to end: a `baton://` deep link
created a worktree, ran the repo's setup script, started an agent, streamed its transcript,
persisted every event, produced a real diff, and rendered that diff in the inspector. Four
agents have been run in parallel in four worktrees without interfering with each other.

Three live tests (`BATON_LIVE=1 ./test-core.sh LiveAgent`) run against the real `claude` binary
and cover a full turn with tool use, session resume across two runner instances, and
cancellation. They are opt-in because they spend tokens.

### Bugs found by running it, all fixed and covered by tests

- Cancelling a turn was recorded as a failure, because the CLI reports `error_during_execution`
  on its way out after SIGTERM.
- The UI wrote whole `Session` rows, clobbering the agent session id the runner had just saved,
  which silently broke resume. The UI now writes only the columns it owns.
- A `baton://` link opened a second window, because a `WindowGroup` makes one per URL.
- The bottom panel sat on a spinner forever when a workspace selected a terminal before its
  tabs had been read from the store.

### Bugs found by adversarial review, all fixed and covered by tests

The worst of these were proved with reproductions rather than argued.

- **Archiving destroyed uncommitted and unpublished work.** It ran `worktree remove --force`
  and `branch -D` with no checks. Now it computes a safety report first, refuses by default,
  and the UI names exactly what would be lost before the user can confirm.
- **A branch named `--mirror` turned `git push` into `git push --mirror`**, deleting a
  remote-only branch. Every ref now goes through a validator and an explicit refspec.
- **A valid `1e100` in the event stream crashed the app**, because every JSON number became a
  `Double` and then an unchecked `Int`.
- **Pressing Stop bricked the session.** Cancelling the task iterating an `AsyncStream` kills
  that stream permanently, so every later turn ran invisibly. The runner now multiplexes.
- **Quitting orphaned every child process.** Agents kept editing worktrees and dev servers kept
  their ports. There is now a real termination path, and signals go to the process group so
  grandchildren die too.
- **`Cmd+W` quit the whole app**, killing every running agent, because the Close Session command
  was in a menu group SwiftUI had dropped.
- Ordinary Unicode filenames (`café.txt`) were misparsed, because git's quoted output was split
  as text. All path parsing is now NUL delimited and byte based.
- Sequence numbers were allocated non-atomically, so two rows could claim the same position.
  Allocation and insert are now one transaction, with a unique index behind it.
- The inspector showed the previous workspace's file contents after switching.
- The diff never refreshed while an agent iterated on the same file.
- Every visible transcript row re-decoded its JSON on every streamed token.

## Non-goals

Cloud workspaces, auth, teams, the public API, non-Claude agent backends, checkpointing.
Everything here runs locally against the `claude` CLI and `git`.

## Architecture

- Swift 6, SwiftUI, macOS 26+. Built with SPM, wrapped into an `.app` by `build.sh`.
- One dependency: SwiftTerm (embedded terminal). Everything else is stdlib + system SQLite.
- Persistence: SQLite via the system `SQLite3` module, thin hand-rolled layer (`Store`).
- All git/gh/claude interaction is subprocess based. No libgit2.
- Core logic (git engine, NDJSON decoding, diff parsing) lives in a `BatonCore` target with
  tests. SwiftUI views live in `Baton` and are not unit tested.

## Phases

Each phase has an endgoal that is checkable by running something.

### Phase 0: Foundation
SPM package, app bundle build script, three-pane SwiftUI shell.
**Endgoal:** `./build.sh && open .build/Baton.app` shows a window with sidebar, center, inspector.

### Phase 1: Data layer
`Store` over SQLite. Models: Repo, Workspace, Session, Message, TerminalSession, Settings.
Migrations. Observable repository objects.
**Endgoal:** repos and workspaces survive an app relaunch. Tests cover the store.

### Phase 2: Git worktree engine
Add a repo, create a workspace (worktree + branch), list, archive, delete. Copy `.env*`.
Run the setup script. Branch names derived from the prompt.
**Endgoal:** creating a workspace in the UI produces a real entry in `git worktree list`,
and archiving removes it.

### Phase 3: Agent runtime
Spawn `claude -p --input-format stream-json --output-format stream-json
--include-partial-messages`, feed user turns to stdin, decode the NDJSON event stream into
typed events, persist them, resume by session id.
**Endgoal:** type a prompt in the composer, the agent works in the worktree, events stream
into the transcript and survive a relaunch.

### Phase 4: Transcript UI
Per-block renderers: text, thinking (collapsible), tool_use for each built-in tool with its
own compact form, tool_result folding, streaming partials, durations, token counts,
unread tracking with "next unread".
**Endgoal:** a real session renders legibly and scrolls smoothly while streaming.

### Phase 5: Changes panel
`git diff` against the merge base, file list with +/- counts, unified diff view with syntax
highlighting, file tree/list toggle.
**Endgoal:** the inspector shows changed files for a workspace and renders their diffs.

### Phase 6: Terminal
SwiftTerm embedded, multiple tabs, cwd set to the worktree, environment carrying
`BATON_*` vars. Setup and Run script tabs.
**Endgoal:** a working interactive shell inside the workspace, plus a Run tab that executes
the configured run script.

### Phase 7: GitHub
`gh` for PR discovery, status, checks, merge. Header bar with PR number, check state, merge.
**Endgoal:** a workspace with a pushed branch shows its PR and check status, and can merge.

### Phase 8: Polish
Unread badges, notifications on turn completion, sidebar grouping and reordering, settings
UI, keyboard shortcuts, workspace search, launch-at-login.
**Endgoal:** usable daily without touching Conductor.

## Conventions

- No em dashes in any user-facing string.
- `BatonCore` must not import SwiftUI.
- Every subprocess call goes through `Shell`, which is cancellable and captures both streams.
