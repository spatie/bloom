# Standalone server preview

Client implementers: see [the wire protocol guide](SERVER-PROTOCOL.md) and [schemas and Python example](../Protocol/README.md).

Bloom can connect to a standalone server while its existing local workspaces remain available.
The server owns its agent processes, worktrees and SQLite database. Closing the server window,
quitting the Mac client or disconnecting SSH leaves those agents running.

The Mac app requires macOS 26. The server has macOS and Linux build paths, sharing the same
runtime and agent backends. Linux validation runs in the Server workflow using Swift 6.3.3 on
Ubuntu 24.04. Existing local sessions still run inside the desktop app; they are not automatically
moved into this server. New server workspaces can run locally or on another machine.

## Add Server assistant

Choose **+** in the bottom-left sidebar footer, then **Add Server…**. The same command is available
in the File menu and the workspace destination menu, including when a server is already connected.
It opens a fresh setup form. Enter `root@server-ip` (or an administrative SSH account with passwordless
sudo), and select a key or use your SSH agent. Existing trusted host keys are copied into the
app's private trust store. New hosts show their Ed25519 fingerprint for explicit verification;
changed and revoked keys are refused. Automatic first-time key discovery supports direct IPv4
and DNS connections; advanced SSH routes need their host verified with SSH first.

Create the Ubuntu machine with your hosting provider first; Bloom installs and configures the
software on that machine. Saved connection profiles retain earlier servers when you add another.
Use **Server Settings > Saved servers**, or **Switch Server** in the server's sidebar menu, to
change the active remote connection. This Mac's projects remain available alongside it. Profiles
contain addresses and references to local key files, never the private key contents or access tokens.

The assistant checks Ubuntu 24.04/26.04 x86_64, systemd, administrator access, free disk space and
existing installation ownership. Set Up Server uploads the package bundled with Bloom, verifies
its checksum, installs Git, tmux, gh, Node and npm, and creates a dedicated `bloom` account. The
account has no sudo privileges. Its home, data and SSH keys are private; the app generates a
separate client key and uploads only its public half. Normal connections and agents run as that
account. No TCP control listener or public development port is opened.

GitHub, Codex and Claude sign-in use an embedded terminal under the service account. Agent CLIs
are installed into its own `~/.local` directory when selected. Account setup is optional for
browsing an empty server, but private GitHub repositories and agent turns require their respective
sign-ins. Reopen Guided Setup to return to the account step for a managed server. The final step
opens Bloom's existing repository picker.

The optional browser step installs a pinned agent-browser and Chrome for the service account,
then verifies the browser sandbox and a screenshot. A browser setup failure leaves the core
server usable and offers a retry. This host browser is separate from browser tooling inside a
project's Docker container. See [browser provisioning](SERVER-BROWSER.md) for the boundaries.

Failures retain the address and selected key. Installation progress is bounded, and raw SSH or
package-manager output is not copied into alerts. Repeating a successful installation of the same
package adds the client key if needed and reuses the service. Updating a different package refuses
a running server; stop it when idle before retrying. Startup failure restores the prior binary and
database. This conservative update path does not yet provide a maintenance-mode handover.

Release builds bundle a matching Ubuntu package automatically. Development builds can set
`BLOOM_LINUX_SERVER_ARCHIVE=/absolute/path/bloom-server-linux-x86_64.tar.gz` before building the
app. The archive must include the matching protocol version from `Tools/package-linux-server.py`.
A build without that payload explains that installation is unavailable and retains advanced
connection settings. The assistant configures SSH; HTTPS gateway deployment remains separate.

## Build and run

### Bloom Remote verification app

`make remote` builds a pinned release copy at `~/Applications/Bloom Remote.app`. It has its own
bundle identifier, preferences, database fallback and local background service. It launches the regular
Bloom interface, with local and remote workspaces together in its normal sidebar. Installation
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

Bloom Remote connects to the preset server on launch. **New Workspace > Create on** chooses
**This Mac** or the configured remote host. Local creation retains Bloom's existing flow. Remote
creation accepts a repository path on the server or an HTTPS/SSH Git URL, clones when needed,
creates a worktree and runs the project's setup script. Remote conversations open in the main
window using the same tab strip, split panes, composer, transcript, inspector, diff viewer and
file editor as local workspaces. Tabs can be closed, renamed and rearranged. Remote notes are
stored on the server. Closing a terminal tab stops that server shell; quitting the client only
detaches it. Remote projects group their workspaces using the same sidebar rows and menus.
Names, colours, pins, unread marks and archive status live on the server. Collapsed projects
and tab layouts stay on each client. Archive confirmations are computed and rechecked on the
server; archived workspaces can be restored with their conversation history and notes.

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

## Codex sandbox on Ubuntu

Ubuntu's AppArmor policy can block the user namespaces Codex needs, producing a Bubblewrap
loopback error before a command starts. Install an application-specific profile for the actual
native Codex executable when necessary, following [Ubuntu's user namespace guidance](https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890).
The npm launcher is not the native executable; find the binary under its platform package first.

For a root-owned native binary at `/opt/codex/bin/codex`, a profile can use this form:

```text
abi <abi/4.0>,
include <tunables/global>

profile bloom-codex /opt/codex/bin/codex flags=(unconfined) {
  userns,
  /opt/codex/bin/codex mr,
}
```

Load the profile with `apparmor_parser`, then verify the installed CLI's sandbox command both
runs a harmless command and refuses a write outside its allowed workspace. The validation host
uses a profile for its exact native binary and retains the global user-namespace restriction.
Its sandbox probe succeeds and an outside-workspace write fails with a read-only filesystem error.

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

Enter an SSH host or alias, the absolute `bloom-server` executable path, and its absolute data
directory. The connection window only configures the host. Its workspaces appear in Bloom's main
sidebar beside local projects, and the workspace title identifies the execution host.

Before connecting remotely, verify ordinary SSH access in Terminal. The client requires an
already trusted host key and non-interactive authentication, usually a key loaded into ssh-agent.
Port, identity and jump-host configuration can live in `~/.ssh/config`. Bloom does not accept new
host keys silently or collect SSH passwords. If an SSH agent requires per-application approval,
authorise Bloom in that agent or choose an existing private key with **SSH key (optional)**.
An explicit key uses `IdentitiesOnly` and disables agent lookup for that connection. The private
key stays on the Mac; only its path is saved in the connection profile. The `BLOOM_REMOTE_IDENTITY_FILE`
build preset accepts the same path.

The bundled `LocalServerService` can register a separate managed local runtime through
ServiceManagement. This remains infrastructure for the eventual local migration; **This Mac** in
the workspace picker currently uses the existing local execution path. It does not migrate an
existing database or change the lifetime of existing local agents.

The remote connection runs `bloom-server connect --data-dir ...` over SSH. That short-lived
process relays protocol messages to the existing server's private Unix socket. It does not start
another server or own the coding agents. No public HTTP listener or Bloom account is involved.

Remote workspaces support prompts and streaming, permission answers, stopping and queued prompts,
multiple conversations and session settings. The inspector lists files and changes, displays diffs,
and edits UTF-8 files with a revision check that refuses overwriting newer server contents. Text
files and diffs are limited to 2 MB. Attachments upload to ignored workspace scratch storage, and
file previews download a copy for the Mac's existing Quick Look renderer, up to 8 MB.

Install `tmux` on the server for persistent terminals. Linux runs it in the foreground under the
Bloom server to avoid a Foundation process-wait issue with daemonising children. Closing the Mac
app detaches the SSH terminal client; the shell and its commands keep running. Stopping the server
service can stop its tmux process too.

The normal tab chrome shows conversations, terminals and previews together. Additional terminal
tabs are remembered by the Mac client and reattach to the server's shells. Project run scripts
appear in the New Tab and Workspace menus, execute on the server and receive the same workspace
environment and allocated port as local scripts. Retrying a completed command returns its original
terminal rather than launching another copy.

The Preview pane first asks the server whether a localhost address has a private Tailscale Serve
mapping. If it does, the browser opens that HTTPS address directly. The address can also be opened
on another device connected to the same tailnet, without keeping the Mac running. Bloom refuses
to use a mapping with public Funnel enabled. Unmapped localhost HTTP/HTTPS addresses use an SSH
tunnel bound only to the Mac's loopback interface. Start the development server in the remote terminal, then open its
address in Preview or click a localhost link in the conversation. Git controls can commit all
changes, push the workspace branch and create a draft or regular pull request using the server's
authenticated `gh`. Credentials remain on their respective execution host.

See [Private remote previews](REMOTE-PREVIEWS.md) for Tailscale setup and Laravel/Vite configuration.

An additional HTTPS transport is in development on this branch. Its native login and gateway
accept administrator-configured OAuth providers, with no mandatory Cloudflare account or VPN.
The gateway uses the same RPC protocol and streams the server's persistent tmux terminals.
See [HTTPS gateway configuration](../Gateway/README.md) for the provider contract, preview
isolation and remaining live sign-in/deployment checks. Installed validation builds may still
use the previous protocol until the app and server are upgraded together.


## Protocol and ownership

`ServerRequest` and `ServerReply` are versioned, newline-delimited JSON values. `BloomWire.version` declares the wire version. A protocol mismatch
is refused before dispatch. Commands and replies carry UUIDs, so a long setup command does not
block transcript reads or controls on the same connection.

Mutations record the complete request before executing and their result afterwards. Retrying the
same UUID returns the recorded result. Reusing it for different input is refused. If the server
crashes between those writes, a retry reports the uncertain outcome and asks for inspection; it
does not silently execute a possibly completed command again. Receipts currently remain in the
server database without automatic expiry.

`ServerRuntime` owns one `ServerSession` per session ID. Each owns one runner and event consumer.
Client disconnect does not cancel those tasks. A second prompt while a turn is busy enters the
durable delivery queue described below. Permission answers are checked against current
pending requests and serialised per question, so two clients cannot answer one twice.

The client refreshes the catalogue every three seconds and loaded transcripts in the selected workspace every second.
Transcript reads use sequence cursors with pages of 500 messages. Pending questions and the
bounded live text tail are refreshed with each page. This is snapshot polling, not a push event
subscription. On connection failure, the client reconnects automatically with a bounded backoff, retaining the
last transcript and selected conversation. Drafts are remembered separately for each session. Connection
generations prevent replies from an old connection replacing a new server's state.

Remote transcript rendering does not resolve server file or attachment paths against the Mac's
filesystem. File reads reject absolute paths, traversal, external symlinks and special files.
Remote message IDs receive unique presentation identities before entering shared transcript caches,
so overlapping SQLite row IDs from local and remote databases cannot display each other's content.
Diff requests resolve the changed-file metadata on the server and use literal git pathspecs.
Diff and file refreshes run separately from conversation refreshes, so a slow git command does
not stall the transcript.

Prompt delivery is durable and belongs to the server. A second prompt waits while the current
turn runs. Stop pauses pending deliveries; sending again resumes them. Each delivery records an
attempt before it reaches the agent. After a crash, an uncertain attempt stays visible for review
and removal instead of being replayed. A queued prompt that was never attempted resumes when the
server starts, even without a connected Mac.

## Remaining work

1. Move the existing desktop execution path onto the standalone runtime. Preserve workspace data,
   startup, shutdown and existing bridge behaviour when migrating existing local workspaces.
2. Publish stable release downloads and broaden Linux coverage across agent backends and ARM64.
   The bundled x86_64 package and guided SSH installer are implemented.
3. Close the remaining interaction gaps across Mac, iPhone and iPad. Remote mid-turn messages
   queue rather than steering the running agent, and global owner-only UI actions are not exposed
   through a workspace lease. Shared creation, crew management, tool cards, native terminals and
   workspace-scoped pane/browser MCP actions are implemented.
4. Display multiple remote catalogues concurrently, add push events and remote transcript search.
   Saved machine profiles currently switch one active remote connection.
5. Broaden attachment limits and preview navigation across multiple forwarded origins.
6. Generate complete public wire records and language SDKs from the protocol contract. Native
   iPhone/iPad clients exist; a browser client and an operated relay remain separate future work.


## Verification

`./Tools/test-core.sh ServerRuntime ServerReview ServerWorkspace ProcessPipeLifetime` exercises real Unix socket connections with fake agent
runners, duplicate and interrupted commands, concurrent prompts and approvals, reconnect,
protocol compatibility, exclusive server ownership and SSH quoting. It spends no model tokens.
`swift build` builds both the Mac client and the standalone server. The Linux workflow also runs
an isolated `BLOOM_FD_STRESS=1` check that repeatedly spawns Shell, Git and streaming processes and
asserts the process's descriptor count stays bounded. This caught pipe retention that short-lived
tests missed. Codex approval IDs include the connection identity so resuming a stored thread cannot
reuse an old permission decision.

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

### Shared creation

New Workspace and Start a Project use the same views for This Mac and the configured server.
The machine menu selects where repositories, branches, pull requests and project folders are
read. Browse GitHub lists repositories using that machine's authenticated `gh` account and
clones the selected repository there. Credentials are never copied between machines.

Remote workspace creation carries the selected base or checkout, composer controls, setup
choice and staged attachments to the server. Chat creation queues its opening prompt once;
terminal and browser creation do not create an agent session. A failed setup retains the prompt
as a draft. Project folder inspection and creation use the same core planner on both machines,
and the server refuses creation if the inspected folder facts have changed.

### Remote review performance

Protocol 11 adds conditional review snapshots and per-file patches. An unchanged response carries
only its revision. The client holds one review request open for up to 15 seconds; filesystem
notifications wake it when a review changes. FSEvents is used on macOS and inotify on Linux,
including the worktree's separate Git directory and common refs. A 30-second full scan is a
backstop for missed events; watch-limit failures on Linux reduce that interval to two seconds.

The server shares scans and concurrent patch requests across clients, limits patch generation to
four concurrent jobs, and retains at most 32 MiB or 128 patches. It watches at most eight recently
used worktrees, with up to 4,096 directories per Linux watcher. File revisions include the resolved
base and inode, size, mode, nanosecond modification/change timestamps, including renamed paths.
This catches edits that keep the same line counts or restore the modification time. A patch is
checked again before it enters the cache.

The Mac retains up to 16 MiB or 64 raw patches per visited workspace and reuses parsed
presentations for small patches (up to 256 KiB, eight presentations). The shared lazy review list
loads file sections near the viewport. A file's revision participates in the view's load identity,
so another file changing does not invalidate every visible diff. Scope changes cancel outstanding
client waits. The existing 2 MiB per-file/patch safety limit remains.

Run `Tools/benchmark-server-review.py` against a packaged server to compare the legacy and new
RPCs in an isolated repository and daemon. It launches no agent and cleans up its own fixture.
The recorded run in `benchmarks/remote-review-2026-09-09.json` used real SSH, 1,000 changed files
(400 changed lines each), 30 opened files, and an additional 100 ms delay per request. This models
extra round-trip latency, not packet loss or a bandwidth-limited mobile connection. Thirty patch
loads took 9.644 seconds with the legacy path and 5.276 seconds with the cached path; its initial
snapshot took another 0.690 seconds. Ten unchanged list checks fell from 1,142,230 bytes to 4,110
bytes. The changed-file notification arrived in 0.903 seconds, including the artificial delay.
These are transport/Git measurements, not a measurement of UI frame rate.

Server labels are stored in the Mac client's connection preferences; renaming one does not alter
the hostname. This Mac and the server label form flat sidebar groups. Server settings, connection
controls, project creation and archived workspaces are available from the server heading.

### Setup and server checks

Setup output is saved as a bounded tail while the script runs, including its last line before a
quiet download. Reconnecting clients see the current attempt. Retry clears the old failure and
runs once even when a connection resends the same command. The server refuses a new setup while
agents are running, awaiting approval or have queued prompts. Read-only workspace queries keep
working during setup.

Browser-first workspaces open their allocated preview after successful setup. The intent belongs
to the original untouched tab, survives reconnecting, and waits through a failed attempt until a
retry succeeds. Typing another address or closing the tab cancels it. Open Preview is also available
from the shared tab menu and browser empty state.

Protocol 13 adds read-only server checks. In Server Connection, choose Check Server to inspect
Git, tmux, GitHub authentication, Docker access, agent CLI discovery, disk space and Linux memory
and file-watch limits. Checks describe the service account, not the connected Mac. Optional missing
tools do not prevent ordinary projects from working. Authentication errors and slow probes return
advice without exposing command output or credentials. Container-provided tools and other mounted
disks are not inspected.

An administrator can run the same checks without starting a daemon:

```sh
bloom-server doctor --data-dir /var/lib/bloom/data
bloom-server doctor --data-dir /var/lib/bloom/data --json
```

Run this as the account that runs Bloom Server. It changes no configuration and exits 1 when a
check needs attention, 0 otherwise, or 64 for invalid arguments. Update the server, Mac client and
HTTPS gateway together: all enforce the same protocol version. The gateway contract test checks
its version against the Swift source to catch future drift.
