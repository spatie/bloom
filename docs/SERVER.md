# Standalone server preview

Bloom can connect to a standalone server while its existing local workspaces remain available.
The server owns its agent processes, worktrees and SQLite database. Closing the server window,
quitting the Mac client or disconnecting SSH leaves those agents running.

This branch implements the first client/server slice. Both the server and the Mac app currently
require macOS 26 and Swift 6.2 to build. Linux support and automatic management of a local server
are subsequent work. Existing local sessions still run inside the desktop app; they are not
automatically moved into this server.

## Build and run

From the repository:

```sh
swift build --product bloom-server
mkdir -p "$HOME/.local/bin"
cp .build/debug/bloom-server "$HOME/.local/bin/bloom-server"
mkdir -m 700 "$HOME/.bloom-server"
"$HOME/.local/bin/bloom-server" serve --data-dir "$HOME/.bloom-server"
```

The server runs in the foreground. Install and authenticate the agent CLIs, git and gh on the
server machine under the same user account. The server uses those credentials and the existing
Bloom agent backends. It does not transfer credentials from the client.

Use a dedicated data directory owned by the server user with mode 700. The database is named
`server.sqlite`. Do not point the desktop app at that database. An exclusive process lock is
acquired before opening SQLite or replacing the socket, so starting a second server cannot reset
live session state or take over its socket.

## Keep the server running

On the server Mac, create `~/Library/LaunchAgents/be.spatie.bloom.server.plist`. Replace the example
home directory with that account's absolute home path:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>be.spatie.bloom.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/developer/.local/bin/bloom-server</string>
        <string>serve</string>
        <string>--data-dir</string>
        <string>/Users/developer/.bloom-server</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/Users/developer/.bloom-server/stdout.log</string>
    <key>StandardErrorPath</key><string>/Users/developer/.bloom-server/stderr.log</string>
</dict>
</plist>
```

Stop the foreground server before loading the service:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/be.spatie.bloom.server.plist"
```

To stop the service and its agents:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/be.spatie.bloom.server.plist"
```

This LaunchAgent runs in the signed-in user's session. It is not a system service that runs before
login. The server machine must stay awake and online; this preview does not change its power
settings. A server restart stops the old processes. Persisted conversations can be resumed by
sending a new prompt, but interrupted tasks are not automatically replayed.

## Connect from Bloom

Build the Mac app from the same branch. Choose **File > Connect to Server…**.

- **This Mac:** supply the standalone server's absolute data directory.
- **Remote machine:** supply an SSH host or alias, the absolute `bloom-server` executable path,
  and its absolute data directory on that machine.

Before connecting remotely, verify ordinary SSH access in Terminal. The client requires an
already trusted host key and non-interactive authentication, usually a key loaded into ssh-agent.
Port, identity and jump-host configuration can live in `~/.ssh/config`. Bloom does not accept new
host keys silently or collect SSH passwords.

The remote connection runs `bloom-server connect --data-dir ...` over SSH. That short-lived
process relays protocol messages to the existing server's private Unix socket. It does not start
another server or own the coding agents. No public HTTP listener or Bloom account is involved.

The server window can create workspaces from repositories already on the server, run configured
setup scripts, send prompts, read conversations and streamed text, stop turns and answer pending
permissions and questions. Its Changes inspector shows branch or uncommitted diffs and reads
current text files from the server, including rename and deletion diffs. Files and patches are
limited to 2 MB; binary files have no text-file view. Each new workspace has an initial chat. Both Claude Code and Codex
use the same implementations as the existing desktop app.

## Protocol and ownership

`ServerRequest` and `ServerReply` are versioned, newline-delimited JSON values (currently version 2). A protocol mismatch
is refused before dispatch. Commands and replies carry UUIDs, so a long setup command does not
block transcript reads or controls on the same connection.

Mutations record the complete request before executing and their result afterwards. Retrying the
same UUID returns the recorded result. Reusing it for different input is refused. If the server
crashes between those writes, a retry reports the uncertain outcome and asks for inspection; it
does not silently execute a possibly completed command again. Receipts currently remain in the
server database without automatic expiry.

`ServerRuntime` owns one `ServerSession` per session ID. Each owns one runner and event consumer.
Client disconnect does not cancel those tasks. A second prompt while a turn is busy is refused;
server-side prompt queuing is not implemented yet. Permission answers are checked against current
pending requests and serialised per question, so two clients cannot answer one twice.

The client refreshes the catalogue every three seconds and the selected transcript every second.
Transcript reads use sequence cursors with pages of 500 messages. Pending questions and the
bounded live text tail are refreshed with each page. This is snapshot polling, not a push event
subscription. On connection failure, the client requires an explicit reconnect. Connection
generations prevent replies from an old connection replacing a new server's state.

Remote transcript rendering does not resolve server file or attachment paths against the Mac's
filesystem. File reads reject absolute paths, traversal, external symlinks and special files.
Diff requests resolve the changed-file metadata on the server and use literal git pathspecs.
Diff and file refreshes run separately from conversation refreshes, so a slow git command does
not stall the transcript. File editing and attachment downloads are not implemented yet.

## Remaining work

1. Move the existing desktop execution path onto the standalone runtime and automatically manage
   a local server. Preserve workspace data, startup, shutdown and existing bridge behaviour.
2. Port the runtime's Apple-specific system dependencies and shell assumptions to Linux, with a
   Linux build and process integration tests.
3. Add remote file editing, terminals, browser previews, attachments and the Bloom MCP
   bridge. The server preview currently launches agents without Bloom's custom MCP tools.
4. Share the full workspace UI across local and remote connections, add saved machine profiles,
   model discovery, push events, prompt queues and automatic reconnect.
5. Add a mobile web client and decide whether to operate an encrypted relay for connections that
   should not require SSH or a VPN.

## Verification

`./Tools/test-core.sh ServerRuntime` exercises real Unix socket connections with fake agent
runners, duplicate and interrupted commands, concurrent prompts and approvals, reconnect,
protocol compatibility, exclusive server ownership and SSH quoting. It spends no model tokens.
`swift build` builds both the Mac client and the standalone server.
