# Bloom

A macOS 26 app for running coding agents in git worktrees. One window: a sidebar of projects and
their workspaces, a transcript in the centre, a terminal, an inspector. A workspace is a real
worktree on disk, which is why so much of what follows is about not destroying one.

Longer documents, pointed at rather than repeated here: `README.md` for what the app is,
`RELEASING.md` for signing, notarising and the appcast, `docs/CODEX.md` for the Codex app-server
protocol as measured, `docs/PROTOCOL.md` for Claude Code's stream-json,
`docs/AGENTS-INTEGRATION.md` for how the four CLIs are detected, `docs/PLAN.md` for what is next,
`docs/start-from.html` for what the create sheet's three sources each do, which is a page to open in a
browser rather than to read here.

## Three targets, and the line between them

`Sources/BloomCore` is everything that is not a view: `Store`, `Git`, `Shell`, `WorkspaceManager`,
the agent protocols, the parsers, the models. **It never imports a UI framework.**

`Sources/Bloom` is the SwiftUI app and the only target allowed to import SwiftUI, AppKit, SwiftTerm
or Sparkle.

`Sources/bloom-bridge` is the MCP stdio shim an agent CLI launches as a child process, which
relays lines to the running app over a unix socket. Three lines of `main.swift`; everything worth
testing is `BridgeShim` in the core. It is a relay with nothing to draw, so it is held to the same
line as the core.

`make lint` holds that line for both, and it looks for the framework rather than for a literal,
because `import Cocoa` re-exports the whole of AppKit and `import class AppKit.NSView` names
AppKit without containing the words next to each other. SwiftTerm and Sparkle need no rule: only
the app target declares them in `Package.swift`, so importing either anywhere else does not link.

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

## Where a green answer comes from

Run tests locally, and run the ones that cover what you touched:
`./Tools/test-core.sh DiffParser` rather than `make test`, most of the time. **The full suite is
not a thing to sit and repeat.** The owner is working at this Mac while you run, several agents
build at once, and a day of that took the load average to 205. A sweep of everything on every edit
is how his machine stalls, and the machine stalling costs more than the answer is worth.

**The green that counts is CI on a pushed branch.** `.github/workflows/test.yml` builds the app
target with `-warnings-as-errors`, runs the house rules, parses every script and runs the whole
core suite on a macOS 26 runner, on hardware that is not his. Push, wait for it, and read what it
says before calling anything done. `gh run watch` and `gh run list --branch <name>` are how you
wait without polling the browser.

One detail that has caught people out: that workflow runs on **push to `main` and on pull
request**, and on nothing else. A branch pushed with no pull request open is not built at all, so
opening the pull request is part of asking for the answer rather than a step after it.

The nightly workflow is separate and gates nothing: Thread Sanitizer, coverage and dead code, on a
schedule, because they are too slow to put in front of a push. Read it when you want those
questions answered, and do not wait on it.

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
`WorkspaceModel`), never from a `body` or a button action. `make lint` holds this one too, by
looking for `await Git.` and `await Shell.` under `Sources/Bloom/Views/`: the subprocess calls are
all async and the pure helpers on the same types are not, so the test costs no exception list of
its own. The three helper types above are named in the allow-list because they are what a view
calls **instead** of reaching for a process itself. `CreateWorkspaceSheet` was the last exception,
calling `Git.branches` from its own `.task`; that loading and both branch decisions it fed are
`WorkspaceStartContext` in the core now, tested, so the sheet's entry came off and the allow-list
in `Tools/house-rules.sh` is back to the three helper types it was meant to hold.

## Where a file goes

`Sources/BloomCore` is grouped by subject, one directory deep and no deeper:

    Agent/          running one, its events, its quotas, its turns; Codex/ is its own protocol
    Bridge/         the unix socket, the MCP tools an agent calls back in with
    Git/            git itself, and everything read out of a diff
    GitHub/         gh, pull requests, checks
    Workspace/      creating, starting, archiving, restoring, and a project's own settings
    Transcript/     what a turn is made of: rows, tools, subagents, attachments, prompts
    Persistence/    Store, SQLite, the settings file, the old app's leftovers
    Model/          the row types, the typed ids, and the lifecycle rules over them
    Presentation/   decisions that exist for the window and hold no UI framework
    Ocean/          the chart, which is its own small world
    System/         this Mac: the shell, notifications, updates, other applications
    Support/        small things with no subject of their own

It was 274 files in one directory, which is not a structure, it is a list. The grouping is by
**what a file is about**, never by what it is: no `Extensions/`, no `Helpers/`, no `Protocols/`,
because those tell a reader nothing they could not see from the file itself.

`Presentation/` is the one that needs a sentence. It holds decisions the window needs and that
have no `import SwiftUI` in them: which tab is next, what the sidebar's summary line says, whether
two colours are far enough apart. They are here rather than beside the views for the reason the
whole three-target split exists, and they are in their own directory rather than mixed into the
subjects so that "this is a view's decision, moved" stays visible.

A directory with one file in it is not a subject. Put it in `Support/` and move it out when a
second one arrives. The app target is grouped the same way, by pane rather than by kind, and
`Tools/house-rules.sh` names a handful of these paths in its allow-lists, so a move has to update
it: `make lint` says so immediately, which is the point.

## One subject per file

`AppModel` reached 2,421 lines: four enums and structs stacked above the class, fourteen `MARK`
sections inside it, and not one of those was a decision anybody took. Each arrived as three methods
put beside the last three, because the file was already open.

**A type gets a file. A subject gets a file.** A type that has grown a second subject is split with
an extension in the same directory, named `Type+Subject.swift`. `AppModel+ProjectIcons.swift` and
`AppModel+TranscriptSearch.swift` are the shape, each opening with a paragraph saying what the file
is for; `AppModel+Naming.swift` is the same split without that paragraph, and is the poorer for it.
What stays in `Type.swift` is what nothing else can hold: the stored properties, because Swift has
none in an extension, the initialiser, and the members that genuinely coordinate between subjects.

Two things decide where the cut goes, and neither is taste. A stored property cannot move, so a
grouping that needs one moved is the wrong grouping. And `private` is file scoped, so every member
that leaves either takes the private state it touches with it or forces that state wider. Count the
widenings before splitting. Five files that keep a type's internals are worth more than nine that
publish them, and a cut that widens the properties whose doc comments say they have one writer is a
cut in the wrong place. `Store` is the case that settles it: 2,603 lines around one `private let
db`, where every extension would have to publish the connection, so it stays as it is.

A long file is not the failure, and `make lint` has no rule here because every threshold tried
fired on files that were right. A 1,200 line ceiling needs an exception list the day it is written,
and half of what goes on that list is correct as it stands. Counting top-level types fires on
`CodexEvent.swift` at twenty-two, `Models.swift` at fourteen and eighty other files besides, every
one of them fine. `Store` at 2,603 lines is right and `AppModel` at 2,421 was not, and no number
tells them apart. The failure is a file nobody can find anything in. The question before adding to
one is whether the thing being added is what the file is about, and the answer to no is a new file
rather than a longer one.

## Comments

Comments say **why**, never what, and the good ones name the bug that forced the design. Read the
head of `Tools/build.sh`, `Store`, or `WindowProxyIcon` for the register: a paragraph that explains
what was tried, what broke, and what the measurement was. A comment restating the line under it is
noise; a comment saying "not `.hiddenTitleBar`, because that left the traffic lights floating"
survives the next person who thinks they have a tidier idea.

## Prose

**No em dashes and no en dashes anywhere.** Use a comma, a full stop or brackets. **British
spelling.** The app is called Bloom, and it had another name before it was renamed, which still
arrives from stale memory. `make lint` checks all three, knows the old name so this file does not
have to, and names the file and line.

## Do not take over the machine

The owner is sitting at this Mac, working, while you run. Anything that takes focus, moves the
pointer, opens or closes a window, launches or quits an application, or puts a window in front of
what he is reading is an interruption to a person, not a step in a task. **Ask before doing any of
it.**

Needs permission every time: launching an app in a way that activates it (`open -g` does not, and
is the one to reach for), `NSApp.activate` or anything that makes a process frontmost, quitting or
signalling any application, sending a keystroke or a click or any synthetic event, capturing or
recording the **display**, changing a system setting including the appearance, and opening a
browser or an editor.

Needs no permission: offscreen rendering, anything headless, and capturing **your own** window by
its window id after opening it with `open -g`.

If a piece of work cannot be verified without one of these, say so and stop. An honest "I could
not photograph this" is a better outcome than an interruption, and it is what several agents have
correctly chosen. A capture that films the display shows whatever is in front of your window,
which has twice turned out to be the owner's own screen.

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
LaunchServices, so `~/Applications/Bloom\ Dev.app/Contents/MacOS/Bloom` started by hand gets no
`BLOOM_DB_PATH`. That used to mean it fell back to the real database and defeated every separation
above. It does not any more: with no `BLOOM_DB_PATH`, `Store` derives the directory from
`Bundle.main.bundleIdentifier`, and only `be.spatie.bloom` resolves to `Bloom`. The dev bundle id
resolves to `Bloom Dev`, which is where `make dev` points it anyway; a binary in no bundle at all,
which is `swift run` or `.build/debug/Bloom` and which nothing used to warn about, resolves to
`Bloom (unbundled)` and starts empty. Open it properly all the same, because the check at the foot
of `dev-build.sh` is worth having and because two agreeing mechanisms are the point.

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
