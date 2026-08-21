# Bloom

A macOS 26 app for running coding agents in git worktrees. One window: a sidebar of projects and
their workspaces, a transcript in the centre, a terminal, an inspector. A workspace is a real
worktree on disk, which is why so much of what follows is about not destroying one.

Longer documents, pointed at rather than repeated here: `README.md` for what the app is,
`RELEASING.md` for signing, notarising and the appcast, `docs/CODEX.md` for the Codex app-server
protocol as measured, `docs/PROTOCOL.md` for Claude Code's stream-json,
`docs/AGENTS-INTEGRATION.md` for how the four CLIs are detected, `docs/PLAN.md` for what is next.

## Two targets, and the line between them

`Sources/BloomCore` is everything that is not a view: `Store`, `Git`, `Shell`, `WorkspaceManager`,
the agent protocols, the parsers, the models. **It never imports SwiftUI.** `grep -rl "import
SwiftUI" Sources/BloomCore` returns nothing today and must keep returning nothing.

`Sources/Bloom` is the SwiftUI app and the only target allowed to import SwiftUI, AppKit, SwiftTerm
or Sparkle.

`Tests/BloomCoreTests` depends on `BloomCore` alone. Read `Package.swift`: the test target has one
dependency and it is not the app. **So a decision taken inside a view is a decision nothing can
test.** When behaviour needs a test, and most does, it belongs in BloomCore as a pure function or a
type, with the view calling it. That is the whole reason the split exists.

## Build and test

Everything real is a script in `Tools/`; the `Makefile` is the index.

    make            list the targets        make lint       Tools/house-rules.sh
    make build      compile every target    make test       the BloomCore suite
    make app        assemble a debug .app   make run        release .app, launched
    make master     install ~/Applications/Bloom.app  (see the guard below)
    make dev        install ~/Applications/Bloom Dev.app
    make dev-db     copy the real database into the dev copy

Anything that takes an argument is run directly: `./Tools/test-core.sh DiffParser`,
`./Tools/master.sh v0.3.0`, `./Tools/dev-build.sh --no-launch`.

`./Tools/test-core.sh` mirrors the core sources into a throwaway package with no app target, so one
broken view cannot stop the core suite. Its head documents the environment it reads: `BLOOM_TEST_ID`
for a stable work and build directory, `BLOOM_TEST_RUNS` to run the suite repeatedly and shake out
flakes, `BLOOM_LOCAL_AGENTS=1` and `BLOOM_LOCAL_SETTINGS=1` to assert against this machine,
`BLOOM_LIVE=1` to drive the real `claude` binary (**this costs money**), and
`BLOOM_TEST_SWIFT_ARGS` for flags like `--sanitize=thread`.

**A green `make test` does not mean the app compiles.** The mirror has no app target, so the
core suite has stayed green while `Sources/Bloom` was broken, four times, every one of them a
widened enum leaving a switch in a view non-exhaustive. Run `make build` before committing
anything that adds a case to an enum.

Zero warnings, and `make lint` green, before anything is committed.

## Persistence goes through `Store`

One actor, one SQLite file, and one rule: **`upsert` creates a row, `update` modifies one.**

`upsert` writes every column from the value it is handed, so it is correct only when that value was
built there and then. Hand it a row read a few seconds ago and it carries every column back to what
it looked like then. `update(workspaceID:)` and its siblings read the row inside the actor, apply
the change and write, with no suspension in between.

This is not tidiness. A workspace row has a diff stat refresh writing every six seconds, an archive
that takes seconds of disk work, a panel somebody sits in for a minute, and an agent turn that runs
for ten. Whole-value writes rolled each other back, and the worst of it was a row that said a
workspace was live after its worktree had been deleted. `Tests/BloomCoreTests/WorkspaceWriteIsolationTests.swift`
is that bug written down: a write changes the columns it names and no others. Add a column and
`update` picks it up; reach for `upsert` on an existing row and the bug is back.

## Views

A type conforming to `View` does not run a subprocess. `Shell` and `Git` are reached from a store,
a model or a helper type beside the view (`FileRevert`, `FileIndex`, `TerminalPersistence`,
`WorkspaceModel`), never from a `body` or a button action. `CreateWorkspaceSheet` still calls
`Git.branches` from a `.task`; that is the exception left over, not the pattern to copy.

## Comments

Comments say **why**, never what, and the good ones name the bug that forced the design. Read the
head of `Tools/build.sh`, `Store`, or `WindowProxyIcon` for the register: a paragraph that explains
what was tried, what broke, and what the measurement was. A comment restating the line under it is
noise; a comment saying "not `.hiddenTitleBar`, because that left the traffic lights floating"
survives the next person who thinks they have a tidier idea.

## Prose

**No em dashes and no en dashes anywhere.** Use a comma, a full stop or brackets. **British
spelling.** The app is called Bloom; it was Baton until it was renamed and the old name still
arrives from stale memory. `make lint` checks all three and names the file and line.

## The dev build, and the rules that keep the owner's data alive

Bloom is developed in Bloom. The app you are running inside is the owner's, holding his real
projects, and he is using it right now.

**Never touch any of these.** `~/Applications/Bloom.app`. `~/Library/Application Support/Bloom/`.
The `be.spatie.bloom` UserDefaults domain. Not to test something, not briefly.

**`make dev` is how you get a build you can run.** It installs `~/Applications/Bloom Dev.app`: its
own bundle id `be.spatie.bloom.dev`, and with it its own preferences domain, its own saved window
state and its own notifications; its own database under `~/Library/Application Support/Bloom Dev/`
through `BLOOM_DB_PATH` in `LSEnvironment`, and therefore its own tmux socket; its own `bloomdev:`
URL scheme, so it cannot swallow a `bloom://` link meant for the real copy. It is told apart by a
rust and orange icon, by "Bloom Dev" in the Dock and the switcher, and by `[DEV] ` in front of every
window title. Both copies run at once.

**Open the dev copy with `open`, never by running its executable.** `LSEnvironment` is applied by
LaunchServices. `~/Applications/Bloom\ Dev.app/Contents/MacOS/Bloom` started by hand has no
`BLOOM_DB_PATH` and falls back to the real database, which defeats every separation above.

**`make dev-db`** copies the real database into the dev container so there is something real to look
at. It never writes back. It copies the `-wal` and `-shm` as well as `bloom.sqlite`, because in WAL
mode everything since the last checkpoint lives in the WAL and the main file alone is stale, and it
never opens the real database at all, because opening a WAL database writes to it. It also points
the copied workspace rows at a root that does not exist, so the dev copy can show every workspace
and cannot delete a real worktree. `--keep-paths` opts out and says why you should not.

**`make master` will refuse if you are inside the app it would replace**, because that script
removes `~/Applications/Bloom.app` and kills the process running from it. `Tools/guard.sh` finds the
app either as a real ancestor of this shell or, for a terminal pane whose tmux server has reparented
away, by the socket name derived from the database path. Do not work around it. Build `make dev`
instead.
