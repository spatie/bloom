# Bloom

Bloom is a native macOS app for working with coding agents in Git worktrees. Each workspace has its
own branch and directory. The app puts conversations, terminals, a browser, changed files and pull
requests in one window.

[![Tests](https://github.com/spatie/bloom/actions/workflows/test.yml/badge.svg)](https://github.com/spatie/bloom/actions/workflows/test.yml)
[![Latest release](https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fdownloads.runbloom.app%2Fappcast.xml&query=%2F%2Fitem%5B1%5D%2Ftitle&label=release&style=flat-square)](https://runbloom.app/download)

## Install

Bloom requires macOS 26 or later. Install the signed and notarised app with Homebrew:

```bash
brew install --cask spatie/bloom/spatie-bloom
```

Or [download the disk image](https://runbloom.app/download) and drag Bloom to Applications. Sparkle
checks for updates from inside the app.

Install at least one supported agent CLI on your Mac: [Claude Code](https://claude.com/claude-code)
(`claude`), [Codex](https://developers.openai.com/codex/cli) (`codex`), or Grok (`grok`). Bloom uses
the CLI you choose for each conversation. Git is required; [GitHub CLI](https://cli.github.com)
(`gh`) enables pull request and checks features. Cursor and OpenCode can be detected in Settings but
cannot run conversations yet.

Bloom keeps its workspaces and conversation database on your Mac. It does not require a Bloom
account. Agent CLIs use their own authentication and provider connections.

## Work with Bloom

1. Add a Git repository as a project.
2. Create a workspace for a task. Bloom creates a branch and worktree, copies configured files, runs
   the project's setup script and starts the chosen agent. You can also open an existing branch or
   pull request, or start with a terminal.
3. Follow the conversation, inspect changed files and review the diff against the merge base. Open a
   terminal or browser beside the chat when you need one.
4. Create or merge a pull request from the workspace. Archive the workspace when the work is
   finished.

Workspaces live under `~/bloom/workspaces.noindex` by default. The `.noindex` suffix keeps Spotlight
from indexing every worktree. Bloom also supports multiple chats in one workspace, reusable quick
prompts and subagents that work in the same branch. Conversation workspaces appear below projects
in the sidebar and need no project, Git repository or worktree.

Useful shortcuts include Cmd+N for a new workspace, Cmd+J for a project-free conversation and
Cmd+P to search files in the current project workspace. See [the menu reference](docs/MENUS.md)
for the full list.

### Incoming mails

The built-in inbox is enabled by default. Point your local app's SMTP host to
`127.0.0.1` and port to `2255`, with no encryption or authentication. Bloom Dev uses port `2256` so
it can run beside the regular app. The inbox runs while Bloom is open and keeps its messages in
Bloom's application data between launches. You can turn it off or change the SMTP port in Settings.
The sidebar footer opens the message list. Agents running in Bloom can use its `mail_send` bridge
tool to put plain text test messages in the same inbox, including from projects with no mail setup.

### Browser access (alpha)

Browser access is in alpha and may change or be removed at any time. Bloom can show conversations
in a browser while the Mac app is running. The browser can send
prompts, create projects and workspaces, and inspect transcripts and file references. Some Mac
features, including native diff review and terminal panes, are not available there yet.

On the same Mac, open **Settings > Browser Access**, enable **Allow browser access**, then choose
**Open in Browser**. Bloom opens a one-use link, so you do not need to type an access code. Bloom Dev
also accepts direct connections to `http://127.0.0.1:53544` on the host Mac without a code.

To open Bloom from a phone or another computer through Tailscale:

1. Install [Tailscale](https://tailscale.com/docs/install) on both devices and sign in to the same
   tailnet. Keep Bloom running on the Mac.
2. In Bloom's Browser Access settings, enable access and expand **Manual connection**. Note the
   port in the address and use **Copy Code** for the access code.
3. In Terminal on the Mac, run `tailscale serve --bg PORT`, replacing `PORT` with the port from
   Bloom. For example, Bloom Dev uses `tailscale serve --bg 53544`.
4. Tailscale prints a private HTTPS address such as `https://your-mac.your-tailnet.ts.net`. Open
   it on the other device and enter Bloom's access code. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
   keeps this address within your tailnet.

The hostname names your Mac in Tailscale, not a separate Bloom account. You can [rename the Mac in
Tailscale](https://tailscale.com/docs/concepts/machine-names) if you want a shorter hostname. The
regular Bloom app chooses a new browser port and access code when it restarts. If the port changes,
run `tailscale serve --bg PORT` again with the new port and use the new access code. Bloom Dev keeps
port 53544, but its remote connections still require the code. To stop remote access, run
`tailscale serve off` on the Mac or turn off browser access in Bloom.

### Repository settings

Configure a project in `.bloom/settings.toml`. Put machine specific values in
`.bloom/settings.local.toml`. Both can be edited from the project's settings screen. Supported
settings include setup and archive scripts, named run scripts, files to copy, branch naming, the
browser address and default models.

```toml
[scripts]
setup_file = ".bloom/setup.sh"
archive_file = ".bloom/archive.sh"

[browser]
url = "http://localhost:$BLOOM_PORT"
```

A script named by `setup_file` or `archive_file` runs in the worktree. Setup runs after creation;
archive must succeed before Bloom removes the worktree. Inline `scripts.setup` and `scripts.archive`
are also supported. Bloom supplies `BLOOM_WORKSPACE_ID`, `BLOOM_WORKSPACE_PATH`, `BLOOM_ROOT_PATH`,
`BLOOM_DEFAULT_BRANCH`, `BLOOM_PORT` and other [workspace variables](Sources/BloomCore/Workspace/WorkspaceScriptVariables.swift).

A browser pane normally opens `http://localhost:$BLOOM_PORT`. Set `browser.url` as above or write an
address to the file named by `BLOOM_URL_FILE` from your setup script. The file is ignored by Git and
read when a browser pane opens.

Workspace agents can call `project_setup_guide` for the supported settings format and this copy of
Bloom's current local SMTP port. Incoming mails is configured in Bloom Settings, not in the
repository's `.bloom/settings.toml`.

### Agent bridge

Workspace agents can ask Bloom to open panes, read the browser or terminal, show media, manage
subagents and work with projects and workspaces through an MCP bridge. The bridge scopes a workspace
agent to its own worktree. You can also register it in your own MCP client from Settings. See [the bridge reference](docs/BRIDGE.md) for tools and permissions.

## Build from source

Install Xcode 26 and an agent CLI, then clone the repository:

```bash
git clone https://github.com/spatie/bloom.git
cd bloom
make dev-fast
```

This installs `~/Applications/Bloom Dev.app`. The dev app has its own database, preferences and URL
scheme, so it can run beside a released copy. `make dev-fast` builds current edits; `make dev`
builds committed `HEAD`. Use `./Tools/dev-build.sh --fast --no-install` to compile without
installing or launching.

`Package.swift` is the Xcode entry point. There is no Xcode project. The [architecture guide](docs/ARCHITECTURE.md) explains the `BloomCore`, `Bloom` and bridge targets.
[AGENTS.md](AGENTS.md) indexes the project skills and [CLAUDE.md](CLAUDE.md) contains the
development rules shared by agents and contributors.

```bash
make build       # Compile all targets with warnings treated as errors
make lint        # Check project rules
make swiftlint   # Check Swift style
```

The core tests run through `./Tools/test-core.sh <filter>` or `make test`. They do not compile the
app target, so also run `make build` when changing code. Follow the local test guidance in
[CLAUDE.md](CLAUDE.md) when working on the owner's machine.

## Documentation

- [Architecture and contributing](docs/ARCHITECTURE.md)
- [Agent integration](docs/AGENTS-INTEGRATION.md)
- [Claude Code protocol](docs/PROTOCOL.md), [Codex protocol](docs/CODEX.md), [Grok protocol](docs/GROK.md)
- [MCP bridge](docs/BRIDGE.md)
- [Release process](RELEASING.md)

## Support and licence

Bloom is free, open source and postcardware. If you use it, [send us a postcard](https://spatie.be/about-us) from your hometown and tell us what you are building. We share
them on our [postcard wall](https://spatie.be/open-source/postcards). You can also [support Spatie's open source work](https://spatie.be/open-source/support-us).

See [CONTRIBUTING](https://github.com/spatie/.github/blob/main/CONTRIBUTING.md) to contribute.
Report security issues to [security@spatie.be](mailto:security@spatie.be). Bloom is licensed under
[MIT](LICENSE.md).
