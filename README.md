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
- `claude` (Claude Code) or `codex` on your PATH. Either can drive a chat, and a chat picks one,
  so a single worktree can hold chats on both
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

There is no `.xcodeproj`, on purpose. Open `Package.swift` in Xcode and you get the targets, the
schemes, the debugger and the previews; `CLAUDE.md` has the section explaining what a checked-in
project file would and would not add.

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
`git.branch_prefix_type`, `git.delete_branch_on_archive`, `models.default` and
`models.claude.default_thinking_level`. A key ending in `_file` (`scripts.setup_file`,
`scripts.archive_file`) names an executable file relative to the repository instead of an inline
command.

### A database per worktree

`scripts.setup` and `scripts.archive` are a pair, and together they are the whole answer to what a
worktree does about its database. Setup makes one; archive drops it. Nothing else has to reap
anything, because Bloom will not remove the worktree unless the archive script succeeded.

```toml
[scripts]
setup_file = ".bloom/setup.sh"
archive_file = ".bloom/archive.sh"
```

```sh
#!/usr/bin/env bash
# .bloom/setup.sh, committed and chmod +x. Without the shebang and the executable bit, the file's
# contents are run through zsh instead, which is fine too.
set -euo pipefail

# Both halves: the project, because a branch called main exists in every repository you own, and
# the branch, because you want one database per worktree. Underscores because MySQL will take
# hyphens only in backticks, and 64 characters because that is where it stops taking anything.
database="${BLOOM_PROJECT_NAME}_${BLOOM_WORKSPACE_NAME//-/_}"
database="${database:0:64}"

cp "$BLOOM_ROOT_PATH/.env" .env
sed -i '' "s/^DB_DATABASE=.*/DB_DATABASE=$database/" .env
sed -i '' "s#^APP_URL=.*#APP_URL=http://localhost:$BLOOM_PORT#" .env

mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$database\`"

composer install --quiet
npm ci --silent
php artisan migrate --force
php artisan db:seed --force
```

```sh
#!/usr/bin/env bash
# .bloom/archive.sh
set -euo pipefail

database="${BLOOM_PROJECT_NAME}_${BLOOM_WORKSPACE_NAME//-/_}"
database="${database:0:64}"

# IF EXISTS, because a failing archive script stops the archive, and a workspace whose setup never
# got as far as creating the database would otherwise be one nobody can ever get rid of.
mysql -u root -e "DROP DATABASE IF EXISTS \`$database\`"
```

`$BLOOM_PORT` is the same number in both, and it is the same number after a restart, so the
archive script can also bring down whatever the setup script started on it (`docker compose down
-v`, or killing what is listening). It gets ten minutes to do so.

## Deep links

```sh
open "bloom://prompt=<urlencoded>&path=<urlencoded repo root>"
```

Same shape as Conductor's, so existing scripts keep working.

## How it is put together

```
Sources/BloomCore/     No SwiftUI. Everything testable lives here, grouped by subject.
  Agent/                 Running one: the runners, the events, the quotas, the turns
  Agent/Codex/           The Codex app-server protocol, which is its own vocabulary
  Bridge/                The unix socket and the MCP tools an agent calls back in with
  Git/                   Worktrees, branches, diffs, branch naming, diff parsing
  GitHub/                gh, pull requests, checks
  Workspace/             Creating, starting, archiving, restoring, a project's settings
  Transcript/            What a turn is made of: rows, tools, subagents, attachments
  Persistence/           Store, SQLite, the settings file, the old app's leftovers
  Model/                 The row types, the typed ids, the lifecycle rules over them
  Presentation/          Decisions the window needs that hold no UI framework
  Ocean/                 The chart
  System/                This Mac: the shell, notifications, updates, other applications
  Support/               Small things with no subject of their own

Sources/Bloom/         SwiftUI.
  Design/                Every colour, font and metric, defined once, and the galleries
  State/                 AppModel, WorkspaceModel, TranscriptModel
  Intents/               App Intents, Shortcuts and the Services menu
  System/                The app target's half of talking to this Mac
  Views/                 One directory per region of the window

Sources/bloom-bridge/  The MCP stdio shim an agent CLI launches. Three lines; everything
                       worth testing is BridgeShim, in the core, where the suite reaches it.
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
  machine, the rule that none of it may be rendered, and what `claude mcp add` accepts when
  registering Bloom in a client you started yourself.
- `docs/BRIDGE.md` is the MCP bridge the other way round: what an agent can ask Bloom to do, which
  callers may ask for what, and which of those questions Bloom answers for itself.
- `docs/PLAN.md` is the build order this was written to, kept for the bug reports in it: what
  broke, why, and what now stops it.

## What it deliberately does not do

No cloud workspaces, no accounts, no teams, no HTTP API, no checkpointing. Those are most of
Conductor's remaining surface area and none of them matter for one person on one machine.
