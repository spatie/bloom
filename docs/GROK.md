# The Grok ACP protocol

Ground truth, captured from `grok` 1.0.24 on this machine on 2026-09-08. Headless
`--output-format streaming-messages-json` looks like Claude Code's stream-json and is a trap:
one prompt then exit, and no wire for permission questions. Bloom drives `grok agent --no-leader
stdio` instead, which is ACP JSON-RPC, the same class of protocol as Codex's app-server.

## How Bloom invokes it

```
grok agent [--always-approve] [--model <id>] [--reasoning-effort <level>] --no-leader stdio
```

`--no-leader` is load-bearing. Without it a Bloom chat can attach to the owner's interactive TUI
leader. `GROK_DISABLE_AUTOUPDATER=1` is set in the child environment so update banners cannot
land on stdout.

Working directory is the worktree. Input is JSON-RPC on stdin, output JSON-RPC on stdout. stderr
is tracing and is not merged.

`clientCapabilities` is sent empty. Advertising `fs` or `terminal` makes the agent ask Bloom to
read files and run commands; Bloom is not that client. Grok has its own tools.

## Handshake

1. Client `initialize` with `protocolVersion: 1` and `clientInfo`.
2. Server replies with `agentCapabilities` (including `loadSession` and `sessionCapabilities.resume`)
   and `_meta.modelState` listing models and each model's reasoning efforts.
3. Client notifies `initialized`.
4. Client `session/new` (or `session/resume` with the stored id) with `cwd`, `mcpServers`, and
   `_meta.yoloMode` / `_meta.autoMode` / `_meta.permissionMode`.
5. Server replies with `sessionId`. Bloom stores it as `Session.agentSessionID`.

Model and effort after that travel as `session/set_config_option` with
`value: { "value": "<id>" }`, which is what Grok's own docs show and what a composer chip change
uses on the next turn without restarting the process.

## A turn

`session/prompt` is held open until the turn ends. Bloom therefore must not wait on it inside
`send`: the reply is an event, and a two minute timeout would kill a real turn. Updates arrive as
`session/update` notifications:

- `agent_message_chunk` / `agent_thought_chunk`
- `tool_call` / `tool_call_update`
- `usage_update`
- `available_commands_update` (ignored)

`session/cancel` is a notification. Stop answers pending permission requests as cancelled, then
sends it.

## Permissions

`session/request_permission` is a server-to-client request. The payload is a tool call plus
options (`allow_once`, `allow_always`, `reject_once`, `reject_always`). Bloom maps those onto its
existing prompt rather than drawing a fourth UI. An option the agent did not list is never
invented: a missing match is answered as cancelled.

## MCP

ACP `mcpServers` on `session/new` is additive over `~/.grok/config.toml`. Bloom registers
`bloom-workspace-bridge` there as a stdio server, `env` as an array of `{name, value}` objects.
The owner's own client is a separate `grok mcp add --scope user` command, for the same reason
Claude Code's is `--scope user`.
