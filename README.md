# Bloom

A native macOS app for running coding agents in parallel, each in its own git worktree.

It is a rebuild of [Conductor](https://conductor.build) in Swift, so it can be changed to taste.
Conductor itself is a Tauri app: Rust with a WebKit view. Bloom is SwiftUI with two dependencies
(SwiftTerm for the embedded terminal, Sparkle for updates) and everything else on the system
frameworks.

## What it does

- Add a git repository as a project.
- Describe a task. Bloom creates a branch, a worktree under `~/bloom/workspaces`, copies your
  `.env` files, runs your setup script, and starts an agent in it.
- Watch the agent work in a dense transcript: one line per tool call, expandable.
- See what changed, as a syntax-highlighted diff against the merge base.
- Open a terminal in the worktree, run your dev server, check the pull request, merge it.
- Do all of that for a dozen tasks at once without them treading on each other.

## Requirements

- macOS 26 or later
- Xcode 26 or a Swift 6 toolchain
- `claude` on your PATH (Claude Code)
- `git`, and `gh` if you want the pull request features

## Building

Every script lives in `Tools/`. `make` on its own lists what there is to run, and each target is
a one line call into that directory, so anything with an argument is run directly instead.

```sh
make run     # release build, assembled into .build/release/Bloom.app, launched
make app     # debug build, which is what you want while changing things
make test    # the core suite, no app target needed
make lint    # the house rules no off the shelf linter knows about
```

The suite can be narrowed, which `make` does not wrap:

```sh
./Tools/test-core.sh DiffParser   # one suite
```

There is also a small set of live tests that drive the real `claude` binary end to end: a full
turn with tool use, session resume across two runner instances, and cancellation. They spend
tokens, so they are opt-in:

```sh
BLOOM_LIVE=1 ./Tools/test-core.sh LiveAgent
```

`./Tools/master.sh` builds a commit into `~/Applications/Bloom.app`, which is the copy to use
while agents are editing the tree. `./Tools/release.sh` is the signed and notarised one; see
`RELEASING.md`.

## It reads your existing Conductor config

Bloom reads `.conductor/settings.toml` from a repository as-is, so a project already set up for
Conductor works with no changes. It layers settings files in this order, later winning:

```
~/.conductor/settings.toml
~/.bloom/settings.toml
<repo>/.conductor/settings.toml
<repo>/.bloom/settings.toml
<repo>/.conductor/settings.local.toml
<repo>/.bloom/settings.local.toml
```

Setup and run scripts get both `CONDUCTOR_*` and `BLOOM_*` environment variables, with the same
meanings, so a script written for Conductor runs unchanged:

| Variable | Meaning |
| --- | --- |
| `*_IS_LOCAL` | Always `1`. There is no cloud mode. |
| `*_WORKSPACE_NAME` | The branch name with slashes replaced by dashes |
| `*_WORKSPACE_ID` | The workspace's internal id |
| `*_WORKSPACE_PATH` | The worktree directory |
| `*_PROJECT_NAME` | The project's folder name, cleaned down to letters, digits and underscores. Bloom's own; Conductor has no equivalent. Use it to keep a name unique across projects, since `*_WORKSPACE_NAME` only is inside one |
| `*_ROOT_PATH` | The main checkout |
| `*_DEFAULT_BRANCH` | The repo's default branch |
| `*_PORT` | The first of ten ports allocated to this workspace |

Supported settings keys: `scripts.setup`, `scripts.archive`, `scripts.run` (a string, or a table
of named scripts with a `command`), `scripts.run_mode`, `files_to_copy`, `git.branch_prefix`,
`git.branch_prefix_type`, `git.delete_branch_on_archive`, `models.default`.

## Deep links

```sh
open "bloom://prompt=<urlencoded>&path=<urlencoded repo root>"
```

Same shape as Conductor's, so existing scripts keep working.

## How it is put together

```
Sources/BloomCore/     No SwiftUI. Everything testable lives here.
  Shell.swift            Every subprocess goes through here
  StreamingProcess.swift Long-lived process with a live stdout and an open stdin
  SQLite.swift           Thin wrapper over the system sqlite3
  Store.swift            One actor, all persistence
  Git.swift              Worktrees, branches, diffs, branch naming
  GitHub.swift           gh wrapper for pull requests and checks
  TOML.swift             Enough TOML to read a settings file
  Settings.swift         Layering those files into RepoSettings
  WorkspaceManager.swift Creating, setting up and archiving a workspace
  AgentEvent.swift       Decoding the claude stream-json protocol
  AgentRunner.swift      Supervising one claude process per session
  DiffParser.swift       Unified diffs into something renderable
  SyntaxHighlighter.swift Per-line lexers, no dependency, no regex

Sources/Bloom/         SwiftUI.
  Design/Theme.swift     Every colour, font and metric, defined once
  State/                 AppModel, WorkspaceModel, TranscriptModel
  Views/                 Sidebar, Center, Transcript, Inspector, Terminal, Markdown, Chrome
```

## The documents under `docs/`

Each of these was written by measuring something rather than by remembering it, so they are the
answer to "has this already been worked out" rather than a tour of the code.

- `docs/PROTOCOL.md` documents the `claude` stream-json protocol as verified against the real
  CLI, with a captured session in `Tests/fixtures/`. Read it before touching anything agent
  related.
- `docs/CODEX.md` is the same for Codex's JSON-RPC app-server, plus the decisions that shaped
  the Codex backend and the work still outstanding on it.
- `docs/AGENTS-INTEGRATION.md` is what the four agent CLIs actually put on disk, read off a real
  machine, and the rule that none of it may be rendered.
- `docs/PLAN.md` is the build order this was written to, kept for the bug reports in it: what
  broke, why, and what now stops it.

## What it deliberately does not do

No cloud workspaces, no accounts, no teams, no HTTP API, no checkpointing. Those are most of
Conductor's remaining surface area and none of them matter for one person on one machine.
