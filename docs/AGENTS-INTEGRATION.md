# Agent CLIs

Ground truth for the Agents settings screen, read off this machine on 2026-08-18. Verified, not
guessed. Anything not listed here should be treated as unknown rather than invented.

## Security rule

`~/.claude.json` and `~/.codex/auth.json` contain live credentials: OAuth access tokens, refresh
tokens and possibly an API key. Bloom reads them ONLY to show non-secret, derived facts (email,
organisation, plan, auth method, expiry). A token must never be rendered in the UI, written to a
log, put on the pasteboard, or included in an error message. When a field is missing, say
"unknown", never fall back to printing raw file contents.

## Detection

| Agent | Executable | Version command | Observed output |
| --- | --- | --- | --- |
| Claude Code | `claude` | `claude --version` | `2.1.234 (Claude Code)` |
| Codex | `codex` | `codex --version` | `codex-cli 0.147.0` |
| Cursor | `cursor-agent` | `cursor-agent --version` | not installed here |
| OpenCode | `opencode` | `opencode --version` | not installed here |

Resolve the executable through `Shell.which(_:)`, which already augments PATH for a GUI launch.
The observed output is the shape to parse and not a version to match: both installed CLIs move
weekly, and the two figures above were already a release behind a fortnight later. Two of the four
are not installed on this machine, so "not installed" is a first-class state and has to look
deliberate, not broken.

## Claude Code

Account facts live in `~/.claude.json` under `oauthAccount`. Relevant keys, all optional:

- `emailAddress`, `displayName`, `organizationName`
- `organizationType` (observed `claude_max`), `organizationRateLimitTier` (observed
  `default_claude_max_20x`), `billingType` (observed `stripe_subscription`), `seatTier`,
  `organizationRole` (observed `admin`)

Derive the login method from `organizationType`: `claude_max` reads as "Claude Max account".
An `ANTHROPIC_API_KEY` in the environment means API key auth instead, and takes precedence in
what is displayed. Config file to offer for opening: `~/.claude/settings.json` (a symlink into
the user's dotfiles here, so resolve symlinks before revealing it).

Login command: `claude /login`. Bloom cannot run that inline because it is interactive, so the
button must open it in a terminal, the way `Reveal.inTerminal(_:)` already does.

## Codex

`~/.codex/auth.json` keys: `auth_mode` (observed `chatgpt`), `OPENAI_API_KEY` (null here),
`last_refresh`, and `tokens` with `access_token`, `refresh_token`, `id_token`, `account_id`.

The readable facts are claims inside `tokens.id_token`, a JWT. Split on ".", base64url decode the
SECOND segment, parse as JSON. Do NOT verify the signature and do not pretend to: this is display
only, and the CLI is the thing that actually authenticates.

Claims: `email`, `name`, `exp` (expiry, seconds since epoch), and a nested object under the key
`https://api.openai.com/auth` holding `chatgpt_plan_type` (observed `prolite`),
`chatgpt_account_id`, `chatgpt_subscription_active_until`, `organizations`.

So: Provider `openai`, Plan from `chatgpt_plan_type` (title case it), Auth from `auth_mode`
(`chatgpt` reads as "ChatGPT login", `apikey` as "API key"), Account from `email`.

Config file: `~/.codex/config.toml`. Login command: `codex login`.

## Cursor and OpenCode

Not installed here, so nothing about their auth files is verified. Detect the binary and show the
version if present. Do NOT invent an auth file format for them: show "Connected" only when there
is real evidence, otherwise show that the CLI was found and leave the account block out. Cursor's
config directory is `~/.cursor` (exists here, holds `hooks.json`). OpenCode's is `~/.opencode`
(absent here).

## What Bloom can actually run

Claude Code and Codex. The stream-json protocol in `PROTOCOL.md` is Claude Code's and
`AgentRunner` speaks it; the JSON-RPC app-server protocol in `CODEX.md` is Codex's and
`CodexRunner` speaks it. Both answer to `SessionRunner`, and `AgentKind.canRunWorkspaces` is the
one place that decides which backends a chat can be started on. Cursor and OpenCode are detected
and configurable and neither has a runner, so neither is offered anywhere a chat is started. The
UI must say so plainly rather than implying a connected CLI is a usable backend.

## Registering Bloom in a client the owner runs themselves

Measured on claude 2.1.241 on 2026-08-23, by running the commands.

`claude mcp add [options] <name> <commandOrUrl> [args...]` takes `-e KEY=value` repeatedly and
`-s, --scope <local|user|project>`. `claude mcp add-json <name> <json>` exists as well and takes
the whole server object as one JSON string, so both shapes are a single copyable line. Bloom uses
`add` rather than `add-json`, because the JSON has to be quoted for the shell as well as escaped
for JSON and the result is unreadable in a settings pane, while the `add` form reads as a sentence.

The three scopes are not interchangeable and only one of them is right here. `local` is this
project on this machine, kept in `~/.claude.json` under the project's own key. `project` writes a
`.mcp.json` in the working directory, which is meant to be committed and shared with everyone who
clones the repository. `user` is the top level of `~/.claude.json` and applies to every project on
the machine. Bloom's coupling belongs to the owner and to no repository, so it is `user`, and that
is also the only one of the three that cannot end up in a commit carrying a live token.

The server is registered under a name derived from the running copy of Bloom: `bloom` from the
owner's install, `bloom-dev` from `Tools/dev-build.sh`, and anything else from the same table that
decides which Application Support directory a build may open, slugified. See
`BridgeRegistration.ownerServerName`.

It is deliberately not `bloom-workspace-bridge`, the name Bloom's own per-session `--mcp-config`
uses. That file is additive over `~/.claude.json` rather than replacing it, so a shared name would
put two entries called the same thing in one client: an agent Bloom launched inside a workspace
would meet its own session token and the owner's standalone token under one name.

It is also deliberately not one constant for every copy of Bloom, which is what it was until the
name was derived. `claude mcp add` replaces an existing entry of the same name and says nothing
about it, and `--scope user` is one file for the whole machine, so Bloom and Bloom Dev both handed
out a command claiming the same entry: pasting one silently evicted the other. Deriving the name
from the same table as the database directory means two builds can only collide here if they were
already sharing a database, in which case they share the token beside it too.

Nothing rewrites an entry left over from before that change. Somebody who ran the older command
still has `bloom-owner-bridge` in `~/.claude.json`, and no copy of Bloom answers to that name any
more, so nothing here recognises it as its own. The Settings pane says so and offers
`claude mcp remove --scope user bloom-owner-bridge`.

A session already running does not pick the server up. Start a new one.

The command is offered in two places and generated in one. `BridgeRegistration.ownerAddCommand`
builds it; `CommandLineOffer` draws it, the warning about `.mcp.json` included, for both the
welcome window's command line step and Settings > Command Line. The welcome step is where somebody meets
it, because nobody browses a settings tab they do not know exists, and the pane is where they go
back for it and where Regenerate lives. The step is offered only when there is something to offer:
`BridgeUserRegistration` reads the `mcpServers` table at the top level of `~/.claude.json` and
compares the entry under this copy's name against the shim path, socket and token it would hand
out today. Anything but a match is offered, an unreadable file included.

### The one thing Bloom does write there

The entry holds an absolute path to the shim inside the bundle, it is written once, and nothing
re-derives it. The owner moved Bloom from `~/Applications` to `/Applications` and every agent
started from his own terminal failed from that moment, saying the bridge was down and naming a
path that no longer existed. Per-session registrations were fine throughout, because
`BridgeRegistration.shimPath` derives the shim from the running executable each time; only the
durable entry went stale.

`BridgeUserRegistrationRepair` puts that one string back, on launch, and touches nothing else. It
rewrites only an entry under **this copy's own** name whose `BLOOM_BRIDGE_SOCKET` and
`BLOOM_BRIDGE_TOKEN` are exactly the pair this instance mints, whose `command` names a file called
`bloom-bridge`, and where that path no longer exists. The socket and token pair is the proof of
authorship: the socket comes from the database path through `TmuxSessions.fingerprint` and the
token is minted beside that database, so no other copy of Bloom can produce it. Anything else,
including the legacy `bloom-owner-bridge` entry, an entry somebody aimed at another Bloom on
purpose, and an entry whose shim is still installed, is left exactly as it was. The write is
atomic and puts the file's mode back, because it holds a live OAuth token.

The token is not refreshed by the repair. A move cannot make it stale, and a token that disagrees
means either that the entry was not minted here or that Regenerate was pressed and never
re-pasted, which is a revocation to leave standing. Both of those already show up as
`notRegistered`, so the command goes on being offered and one paste fixes them.
