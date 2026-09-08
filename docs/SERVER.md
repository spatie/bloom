# Standalone server preview

Bloom can connect to a standalone server while its existing local workspaces remain available.
The server owns its agent processes, worktrees and SQLite database. Closing the server window,
quitting the Mac client or disconnecting SSH leaves those agents running.

The Mac app requires macOS 26. The server has macOS and Linux build paths, sharing the same
runtime and agent backends. Linux validation runs in the Server workflow using Swift 6.3.3 on
Ubuntu 24.04. Existing local sessions still run inside the desktop app; they are not automatically
moved into this server. New server workspaces can run locally or on another machine.

## Build and run

### Bloom Remote verification app

`make remote` builds a pinned release copy at `~/Applications/Bloom Remote.app`. It has its own
bundle identifier, preferences, database fallback and local background service. It opens the same
server views used by Bloom, without constructing the normal desktop workspace model. Installation
does not restart any running app.

The first build can embed a connection preset. These values are connection addresses, not agent
credentials, and subsequent builds preserve the installed preset unless explicitly overridden:

```sh
BLOOM_REMOTE_HOST=developer@server \
BLOOM_REMOTE_EXECUTABLE=/opt/bloom-server/bin/bloom-server \
BLOOM_REMOTE_DIRECTORY=/var/lib/bloom/data \
BLOOM_REMOTE_REPOSITORY=/srv/repository \
make remote
```

Bloom Remote connects to the preset server on launch. The toolbar switches between **Remote
server** and **This Mac**. **New Workspace > Create on** also chooses the destination directly.
Local repositories have a folder picker, remote repositories use paths on that server, and each
destination remembers its own repository path. Switching machines disconnects the client while
agents continue on the machine that owns them.

### Standalone executable

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

On Linux, install Swift and the system development dependencies before building:

```sh
sudo apt-get install libsqlite3-dev pkg-config git
swift build --product bloom-server
```

The Linux manifest omits the Mac app and its dependencies. It uses Swift Crypto for the existing
CryptoKit operations and system SQLite. Inline setup scripts use `/bin/sh` on Linux and
`/bin/zsh` on macOS; executable script files retain their own shebangs.

These are source-build instructions. Swift is not installed by default on Ubuntu, and copying
only the executable from a source build is insufficient. The Linux preview package includes
Swift, SQLite and its other required libraries. No separate Swift installation is needed to run
that package. Its glibc and loader come from the host, so this is an Ubuntu package rather than
a fully static executable for every Linux distribution. ARM64 is not yet verified.

## Linux package

The Server workflow builds a `bloom-server-linux-x86_64` artifact and exercises it in fresh Ubuntu
24.04 and 26.04 containers without Swift installed. Download the artifact from a successful run,
extract its tarball and keep the `bin` and `lib` directories together:

```sh
tar -xzf bloom-server-linux-x86_64.tar.gz
mkdir -m 700 "$HOME/.bloom-server"
./bloom-server-linux-x86_64/bin/bloom-server serve --data-dir "$HOME/.bloom-server"
```

Install Git and authenticate the desired agent CLI under the service account. Runtime libraries
are resolved relative to the executable; the package does not change `LD_LIBRARY_PATH` for the
agent processes it launches. Library updates require rebuilding the package.

To produce the same preview package in the Ubuntu 24.04 Swift build environment:

```sh
sudo apt-get install libsqlite3-dev pkg-config git python3 patchelf
swift build --product bloom-server
python3 Tools/package-linux-server.py .build/debug/bloom-server .build/bloom-server-linux-x86_64.tar.gz
```

The package carries licence notices and a manifest of the included libraries. It is a development
artifact, not an automatically published release or installer.

## Keep a standalone server running

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

For Linux, a user service at `~/.config/systemd/user/bloom-server.service` can run the same command:

For a packaged build, set `ExecStart` to the executable inside the extracted package, keeping its
adjacent `lib` directory in place. Use that same executable path in the Mac client's connection.

```ini
[Unit]
Description=Bloom server

[Service]
ExecStart=/home/developer/.local/bin/bloom-server serve --data-dir /home/developer/.bloom-server
Environment=PATH=/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
TimeoutStopSec=20

[Install]
WantedBy=default.target
```

Replace the account paths, then run `systemctl --user daemon-reload` and
`systemctl --user enable --now bloom-server`. To keep a user service running after the last login
session closes, enable lingering for that account with `loginctl enable-linger developer`, or run
a system service configured with `User=developer`.

## Connect from Bloom

Build the Mac app from the same branch. Choose **File > Connect to Server…**.

- **This Mac:** choose Start Local Server. Bloom registers its bundled helper through macOS
  ServiceManagement, connects when it is ready and keeps it available after the app closes.
- **Existing local server:** supply the standalone server's absolute data directory.
- **Remote machine:** supply an SSH host or alias, the absolute `bloom-server` executable path,
  and its absolute data directory on that machine.

Before connecting remotely, verify ordinary SSH access in Terminal. The client requires an
already trusted host key and non-interactive authentication, usually a key loaded into ssh-agent.
Port, identity and jump-host configuration can live in `~/.ssh/config`. Bloom does not accept new
host keys silently or collect SSH passwords.

The managed local server starts at login. If macOS requires background approval, the connection
window offers Open Login Items. Stop Local Server unregisters the service and stops its agents;
Disconnect leaves them running. An incompatible running server is never silently restarted.
Use Stop Local Server and Start Local Server when an app update requires a server restart.

Managed server data lives under Application Support/Bloom Servers, in a directory named for the
app's bundle identifier. Bloom, Bloom Dev and Bloom Subagents have distinct service labels and
databases. The bundle preparation script generates the launch-agent plist after the development
build has set its identity. A bare `swift build` executable cannot register a managed service;
assemble a Bloom app bundle to use this option, or run the standalone command yourself.

The app is distributed outside the Mac App Store without App Sandbox. This registration does not
add sandbox entitlements. ServiceManagement registration must be exercised from an installed,
signed app; the automated packaging checks do not register a service on the developer's Mac.

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

1. Move the existing desktop execution path onto the standalone runtime. Preserve workspace data,
   startup, shutdown and existing bridge behaviour when migrating existing local workspaces.
2. Add stable release downloads and installers, and broaden Linux coverage across agent backends.
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

The Linux package has also been exercised directly on an Ubuntu 26.04 x86_64 host without Swift
installed, and in a fresh Ubuntu 24.04 container. A systemd service restart preserved conversation
history. Boot enablement was checked; a full host reboot has not yet been tested.

`RemoteServerTests` is an opt-in test of the actual Mac SSH client against a disposable server.
Configure that server's `agent.claudeCode.executablePath` setting to the executable
`Tests/fixtures/server-agent.py`. Its repository must contain `bloom-validation.txt` with the
text `Bloom remote protocol fixture` followed by a newline, and a committed `hello.txt` file.
Use a dedicated server database and service account for this fixture.

```sh
BLOOM_REMOTE_TEST_HOST=developer@test-server \
BLOOM_REMOTE_TEST_EXECUTABLE=/opt/bloom-server/bin/bloom-server \
BLOOM_REMOTE_TEST_DIRECTORY=/var/lib/bloom-test/data \
BLOOM_REMOTE_TEST_REPOSITORY=/var/lib/bloom-test/repository \
Tools/test-core.sh RemoteServer
```

This verifies workspace creation, an approval surviving disconnect, file and diff review, stopping
a process and resuming its conversation. The deterministic fixture makes no model calls. Live
provider authentication and model execution are separate checks. A real Codex turn has also been
verified on the Ubuntu 26.04 host: it continued after SSH disconnected, requested approval for a
file change, completed after approval and returned the expected file through the server API.
