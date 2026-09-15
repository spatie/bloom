# Bloom Server

Client implementers: see [the wire protocol guide](SERVER-PROTOCOL.md) and [schemas and Python example](../Protocol/README.md).

Remote servers are in alpha, and off by default in the Mac app. Turn on **Settings > Servers >
Remote servers** to show them: the server section of the sidebar, **Add Server…** and **Server Settings…** in the
File menu and the sidebar footer, and the machine picker in the create windows. With the switch off
Bloom shows none of these, does not connect or poll, and closes any open server windows. Saved
servers are kept, and turning the switch back on reconnects as before.

Bloom can connect to a standalone server while its existing local workspaces remain available.
The server owns its agent processes, worktrees and SQLite database. Closing the server window,
quitting the Mac client or disconnecting SSH leaves those agents running.

The Mac app requires macOS 26. The server has macOS and Linux build paths, sharing the same
runtime and agent backends. The Linux package is built with Swift 6.3.3 on Ubuntu 24.04 and
supported on Ubuntu 24.04 and 26.04 x86_64, which the Server workflow runs it on. Existing local sessions still run inside the desktop app; they are not automatically
moved into this server. New server workspaces can run locally or on another machine.

## Add Server assistant

Choose **+** in the bottom-left sidebar footer, then **Add Server…**. The same command is available
in the File menu and the workspace destination menu, including when a server is already connected.
It introduces remote workspaces and explains the requirements before asking for connection details.
Choose **Get Started**, then enter `root@server-ip` (or an administrative SSH account with passwordless
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
existing installation ownership. Results stay with the editable connection details. Review Installation
shows the changes before Confirm and Install uploads the bundled package, verifies its checksum,
prepares Git, tmux, gh, Node and npm, and creates a dedicated `bloom` account. Compatible tools are
reused, including npm bundled with NodeSource's Node package; only missing packages are installed. The
account has no sudo privileges. Its home, data and SSH keys are private; the app generates a
separate client key and uploads only its public half. Normal connections and agents run as that
account. No TCP control listener or public development port is opened.

GitHub, Codex and Claude sign-in use an embedded terminal under the service account. Agent CLIs
are installed into its own `~/.local` directory when selected. Account setup is optional for
browsing an empty server, but private GitHub repositories and agent turns require their respective
sign-ins. Reopen Guided Setup to return to the account step for a managed server. The final step
opens Bloom's existing repository picker.

Existing-server sign-ins are under **Server Settings > Accounts**, the first settings section.
The GitHub repository picker links to the same account screen when authentication is needed.
GitHub, Codex and Claude use one shared sign-in view in setup and settings. Installation locations
are shown directly in the review step. Optional browser, Docker or swap availability does not block
connecting to the core server.

**Add 2 GB of swap** is selected by default when the server check finds no active or configured
swap. It provides extra room during memory spikes, including development builds, and can be
turned off. Existing active swap and inactive swap configuration are preserved. An unknown check
result never opts the server into swap provisioning.

Swap uses a root-owned `/var/lib/bloom/swapfile` and a dedicated systemd swap unit for subsequent
boots. It stays outside the service account's writable home because that account must not be able
to replace a file activated by root. Provisioning requires 4 GiB free on ext4 or XFS: 2 GiB for the
file and 2 GiB remaining disk space. Unsupported filesystems or insufficient space produce a
copyable error and retry action, while the rest of setup can continue. Bloom never disables
existing swap or rewrites unrelated swap settings.

The optional browser step installs a pinned agent-browser and Chrome for the service account,
then verifies the browser sandbox and a screenshot. A browser setup failure leaves the core
server usable and offers a retry. This host browser is separate from browser tooling inside a
project's Docker container. See [browser provisioning](SERVER-BROWSER.md) for the boundaries.

**Docker for container projects** is selected by default during installation and can be turned off. This installs
Ubuntu's Docker, Compose and rootless dependencies, reserves subordinate user/group IDs and enables
a separate lingering user service. Images and container data live under `~/bloom/docker/data`.
Bloom never joins the rootful Docker group or exposes a public Docker socket. Ordinary Docker
commands use the service account's private rootless context.

On macOS, a Docker-related workspace setup failure offers **Start Docker** beside the retry action.
It starts only an existing, managed rootless user service. If that service is missing, the recovery
window offers explicit administrator SSH setup, preserving the selected server's host-key pin.
Successful recovery can rerun setup in the original workspace. Administrator privileges are needed
for initial provisioning; restarting an already configured user service does not need root.

Repository setup still comes from the selected branch. Bloom does not rewrite a project's macOS
setup script into a Linux one. Container-ready branches should commit their `.bloom/settings.toml`
and setup script, including creation of development environment files when required.

### Storage and cleanup

**Server Settings > Storage & Cleanup** shows capacity on the filesystem containing Bloom's data,
alongside Docker's image, container, volume and build-cache usage. Docker categories share layers
and cannot be added together. Reclaimable build-cache sizes are estimates; image reclaimability
is deliberately not presented because Docker can report it incorrectly for active images.

The reader selects build cache or unused images, reviews the current server, then confirms cleanup.
Cleanup uses only that account's verified, private rootless Docker engine. It never removes
containers, volumes, workspace files, uploads, credentials or swap. Images referenced by either
running or stopped containers stay available. Later builds may need to recreate caches or download
images again. Retained data from archived workspaces is not automatically deleted by this panel.

Only one cleanup runs at a time. Failed or interrupted operations retain per-category outcomes,
with a copyable report and a refresh action. Closing settings does not revoke an already confirmed
cleanup. The server API supports both SSH and authenticated HTTPS clients; older servers without
the storage capability show an update-required state instead of receiving an unknown command.

Failures retain the address and selected key. A step list and selectable live output remain visible
during installation. Structured errors retain the sanitised command, exit status and diagnostic tail;
Copy Error retains the failure diagnostic; Copy Output sits beside the live log. Credential patterns and terminal
control sequences are filtered before display or copying. The retained log is bounded to 1,000 lines
and 256 KiB. Back preserves completed installation work and returns to account setup without reinstalling.

The standalone installers emit JSON lines: `progress` events carry `step` and `message`, `output`
events carry live command lines, and `error` events include `code`, `message`, `recovery` and optional
`command`, `exitStatus` and `details`. The app recognises a final `complete` event only after a successful
process exit. Browser and server installers embed the same subprocess/output helper, so they need no
additional Python package on the server. These setup events are separate from the workspace RPC protocol.

Repeating a successful installation of the same
package adds the client key if needed and reuses the service. Updating a different package refuses
a running server; stop it when idle before retrying. Startup failure restores the prior binary and
database. This administrator installer is also the bootstrap and repair path for the protected
maintenance supervisor. Routine supported updates use the server-owned jobs described below.

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
does not restart any running app by default. For everyday development, `make remote-fast` snapshots
current edits into a persistent debug cache, builds and verifies the full app, then gracefully
restarts only Bloom Remote with `open -g`. Use `Tools/remote-build.sh --fast --no-install` to verify
without touching the installed app, or `--fast --no-launch` to install while Remote is closed.
Fast mode uses four compiler jobs and a cache per checkout under
`~/Library/Caches/BloomBuild/remote/`. It retains normal assets and App Intents metadata. Release
mode still builds the selected committed revision; fast mode cannot take a revision.

Both modes preserve the installed connection preset and client-key path. Set
`BLOOM_LINUX_SERVER_ARCHIVE` to a tested server archive, or the build reuses the installed Remote
app's embedded payload. Missing packages and protocol mismatches stop the build. Its printed
archive SHA identifies the payload; protocol compatibility alone does not mean its server code
matches current edits. Server changes require a newly tested Linux archive.

Fast mode never replaces its own hosting app. `--no-install` is safe from a Remote-hosted session.
Candidate copying/signing finishes before installation, and an atomic directory exchange retains
the previous app if publication fails. `BLOOM_REMOTE_BUILD_ONLY=1` remains supported and exports
`/tmp/Bloom-Remote-ready.app` without installation or launch.

The first build can embed a connection preset. These values are connection addresses, not agent
credentials, and subsequent builds preserve the installed preset unless explicitly overridden:

```sh
BLOOM_REMOTE_HOST=developer@server \
BLOOM_REMOTE_EXECUTABLE=/home/bloom/bloom/server/current/bin/bloom-server \
BLOOM_REMOTE_DIRECTORY=/home/bloom/bloom/data \
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

### Guided installation layout

The Mac assistant shows five steps throughout: Introduction, Server, Installation, Accounts and
Finish. Continue moves between pages; Install is the explicit action that changes the server.
A server that passes every check moves on to Installation by itself, and that page opens with
what the check found (the connection, Ubuntu version and architecture, and any warnings).
The Accounts step first offers credential copying, then a separate page for individual sign-ins.
Import results finish with Done, including partial results, before account status is refreshed.

The introduction lists the requirements before any address is typed: Ubuntu 24.04 or 26.04 on
x86_64, an SSH login as root or with passwordless sudo that is used only for installation and
maintenance, and the separate `bloom` account that runs everything afterwards. The address step
repeats the login rule under the field. The Installation step shows what is installed as a list
(development tools, the account, where projects live, Bloom Server and the maintenance service),
with every path behind one help button, and each optional extra states what it is for and what
it costs in disk space. The wording lives in `ServerInstallationSummary` in the core, and
`ServerUninstallPlanTests` keeps words such as systemd, AppArmor and rootless out of it.

**Server Settings > About This Server** repeats that summary for a connected server: the system
reported by its checks, the installed version when Updates has loaded it, the account and data
directory, what was installed, and the limits that matter. One server is connected at a time and
switching disconnects the current one, clients poll rather than receive pushes, and removing a
server is not uninstalling it.

Remove Server in the sidebar asks for confirmation and forgets only this Mac's saved connection.
It leaves server processes, projects and credentials alone, and retains local drafts and key
files. Its alert says Bloom Server keeps running and points to **Uninstall Bloom Server…**.
Removed bundled presets stay removed on relaunch. Other saved connections remain available
under the sidebar footer's Saved Servers menu.

Server checks keep the problem and available actions visible. Hover over a circled question mark
for recovery details, or click it to open selectable text and Copy Details. Copy Report still
includes every check and its full recovery instructions.

For an existing managed installation, Stop Server asks for confirmation and uses the verified
administrator SSH connection. It verifies the service ownership and checks for work before
stopping that service, then refreshes installation checks. It refuses manually managed processes,
unknown service state and observed active work. This is an explicit administrative stop, not an
atomic maintenance mode: another client can start work after the final activity check. Connected
clients disconnect; projects and conversations remain on disk. Installation starts the service
again. Installation itself never stops a running server automatically.

### Uninstall Bloom Server

**Uninstall Bloom Server…** is in the server's sidebar menu and in **Server Settings > About This
Server**. It uses the same administrator SSH path as setup: the address is prefilled as
`root@host`, the host key is verified and the installer's check must describe the saved server's
installation (host and data directory) before the confirmation is offered. The confirmation lists
what is removed and what stays, from `ServerUninstallPlan`, with one choice: keep the `bloom`
account and its data (the default), or delete it. Progress streams into the same output view as
setup, and the result lists what the installer actually removed and kept, then offers to remove
the connection from this Mac as well.

On the server this is `install-bloom-server.py --uninstall`, with `--delete-data` and `--force`:

- **Always removed:** the `bloom-server.service` unit (stopped and disabled first, and refused if
  its contents are not the unit Bloom writes), the maintenance supervisor's state in
  `/var/lib/bloom-maintenance/<service>`, its socket, and its programs in `/usr/local/libexec`
  unless another installation still has state there. Lingering is turned off for the account and
  its user services stop, which stops rootless Docker containers. Optional parts are removed only
  when their Bloom markers verify them: `/opt/bloom-browser` and its AppArmor profile when they
  belong to this account, the managed swap file and unit (kept and reported if swap cannot be
  turned off), and `/etc/sysctl.d/90-bloom-docker.conf`.
- **Keeping data (default):** the release files in `~/bloom/server` and this Mac's `bloom-client`
  key lines are removed as the account itself. The account, `~/bloom/data`, workspaces and
  sign-ins stay. The installation marker is rewritten as `prepared` with `uninstalled: true`, so a
  later installation adopts the account and its data instead of refusing it as unknown.
- **`--delete-data`:** processes of the account are killed, custom data paths outside its home are
  deleted as the account, then `userdel --remove` deletes the account and its home, and the marker
  is removed.
- **Never removed:** Git, GitHub CLI, tmux, Node.js, npm, CA certificates and Docker packages. The
  completion event lists them as kept.

It refuses with `server_busy` while agents, queued deliveries or workspace setup are active and
with `maintenance_busy` while a maintenance job runs. `--force` (**Uninstall Anyway…** in the app)
continues past those two and an unreadable activity database, and nothing else: a changed unit or
a maintenance configuration that does not match this installation is refused regardless. Every
step checks whether its part still exists and the marker changes last, so an interrupted run can
be repeated; a run with nothing left reports `unchanged: true`. The `complete` event carries
`removed`, `kept`, `deletedData` and `message`.

The wizard creates the `bloom` service account with `/home/bloom` as its home. Bloom-owned runtime
and state use `~/bloom`:

- `~/bloom/server/current/bin/bloom-server`: the installed server executable.
- `~/bloom/data`: server database and runtime data.
- `~/bloom/data/repositories`: imported GitHub repositories, unless a project directory was explicitly configured.
- `~/bloom/workspaces.noindex`: workspace checkouts.
- `~/bloom/data/browser`: mutable browser profiles and state.

The wizard shows the full installation paths before confirmation. Runtime files are written as
the service user; the installer verifies packages in a private administrator directory before
handing them over. Installation ownership metadata remains protected at
`/etc/systemd/system/bloom-installations/bloom-server.json` alongside the service integration.

System packages and systemd journals stay in their OS locations. The reviewed sandboxed browser
bundle stays root-owned at `/opt/bloom-browser`, because its protected launchers and AppArmor
profile depend on trusted executable paths. Agent CLIs use `~/.local/bin`; GitHub, Codex and Claude
use their supported credential locations under the service account's home.

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
Bloom agent backends.

The Mac setup wizard and **Server Settings > Accounts** offer **Use Accounts from This Mac**.
Opening the chooser lists GitHub account metadata and checks for a file-based Codex sign-in.
Nothing is selected by default. Importing is a separate action that names the destination server.
GitHub's own CLI reads the selected account token; Codex imports only its supported file-based
cache. Claude uses its supported sign-in flow instead of exporting private Keychain entries.

Credentials travel directly over SSH with the saved host-key pin, as the installed service user,
never as the setup administrator. They are excluded from command arguments, application logs,
clipboard and Bloom's database. Existing server sign-ins are preserved rather than overwritten.
The result distinguishes successful import from verification that could not finish.

This is intended for servers you trust. Server administrators and code running as the same Bloom
user can use the imported credentials with their original permissions. SSH encryption and private
file permissions do not isolate credentials from that user. Signing out on the server removes its
stored copy; revoking the token with the provider invalidates it and may also sign out the Mac.
A separate provider sign-in remains available, including when the local tool uses a credential
store that cannot be imported. iPhone and iPad clients use accounts already configured on the
server and do not need a copy of those credentials.

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
only the executable from a source build is insufficient. The Linux package includes
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

Every Bloom release attaches `bloom-server-linux-x86_64.tar.gz` to its GitHub release, built in
release configuration, with a `.sha256` and a `.json` description beside it. The Mac app bundles
the same file, and the maintenance supervisor updates servers to it. [RELEASING.md](../RELEASING.md#bloom-server)
describes how it is built and checked. The Server workflow builds the same package for every pull
request and exercises it in fresh Ubuntu 24.04 and 26.04 containers without Swift installed.

Download it, check it, extract it and keep the `bin` and `lib` directories together:

```sh
gh release download --repo spatie/bloom --pattern 'bloom-server-linux-x86_64.tar.gz*'
sha256sum -c bloom-server-linux-x86_64.tar.gz.sha256
tar -xzf bloom-server-linux-x86_64.tar.gz
mkdir -m 700 "$HOME/.bloom-server"
./bloom-server-linux-x86_64/bin/bloom-server serve --data-dir "$HOME/.bloom-server"
```

Install Git and authenticate the desired agent CLI under the service account. Runtime libraries
are resolved relative to the executable; the package does not change `LD_LIBRARY_PATH` for the
agent processes it launches. Library updates require rebuilding the package.

To produce the same package in the Ubuntu 24.04 Swift build environment:

```sh
sudo apt-get install libsqlite3-dev pkg-config git python3 patchelf
swift build -c release --product bloom-server
swift build -c release --product bloom-bridge
BLOOM_SERVER_VERSION=v1.4.0 python3 Tools/package-linux-server.py \
  "$(swift build -c release --show-bin-path)/bloom-server" .build/bloom-server-linux-x86_64.tar.gz
```

Without `BLOOM_SERVER_VERSION` the version is `0.0.0-dev.<commit>`. The package carries licence
notices and a manifest of its version, protocol version and included libraries. For a server that
stays up, use the Add Server assistant, which installs the package as a service with supervised
updates.

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
2. Broaden Linux coverage across agent backends and ARM64. Every release publishes the x86_64
   package, and the bundled package and guided SSH installer are implemented.
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
BLOOM_REMOTE_TEST_EXECUTABLE=/home/bloom/bloom/server/current/bin/bloom-server \
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
terminal and browser creation do not create an agent session. From protocol 15 the server replies
as soon as the worktree exists and runs the setup script afterwards, so the New Workspace window
closes and the workspace shows setup progress, as it does on the Mac. The opening prompt waits in
the chat's queue and is sent when setup ends, whether it succeeded or failed. If a create is still
waiting after two seconds (a large pull request fetch, for instance), the window shows what the
server is doing with a clock, Cancel and Close Window. It reports the server as not responding only
when the connection has gone or nothing has come back from the server for 20 seconds, never
because the create itself is slow. Cancel stops waiting; it cannot stop work the server has
already started, and a workspace that finishes anyway appears in the sidebar. Project folder inspection and creation use the same core planner on both machines,
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
quiet download. The selected workspace streams it once a second through `setupOutput`, with the run's start time,
and the setup row names the current step when the output says it (building the Docker image,
compiling PHP extensions, installing Composer or npm packages) with the live log beneath. A server
restart files a run it was killed during as interrupted. Reconnecting clients see the current attempt. Retry clears the old failure and
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
bloom-server doctor --data-dir /home/bloom/bloom/data
bloom-server doctor --data-dir /home/bloom/bloom/data --json
```

Run this as the account that runs Bloom Server. It changes no configuration and exits 1 when a
check needs attention, 0 otherwise, or 64 for invalid arguments. Update the server, Mac client and
HTTPS gateway together: all enforce the same protocol version. The gateway contract test checks
its version against the Swift source to catch future drift.

Remote pane splits advertise the `pane_split_anchored` UI capability. The MCP tool remains
`pane_split`; Bloom Server supplies the authenticated caller's session ID separately from tool
arguments. New clients resolve that chat before splitting and refuse if it is no longer open.
Older clients without this capability refuse these requests rather than splitting another chat.
The legacy `pane_split` UI action retains its focused-pane behaviour for older servers.

### Server updates

Server Settings > Updates uses server-owned maintenance jobs over either SSH or HTTPS on Mac,
iPhone and iPad. Review the exact target version and restarts, then choose Update or Update When
Idle. Jobs, bounded redacted output and outcomes survive closing the app or losing its connection.
The supervisor continues serving maintenance status while Bloom Server restarts.

Supported installations are deliberately specific:

- **Bloom Server:** compatible, checksummed Linux release assets from `spatie/bloom`. The supervisor
  stages the reviewed release, snapshots the database and verifies startup before committing it.
  Failed trials restore the previous release and database.
- **Claude Code and Codex:** recognised, account-owned npm packages under `~/.local`. Updates pin
  the reviewed package version and preserve sign-in files. Native installers, system packages and
  custom launchers are reported as externally managed, rather than overwritten.
- **Docker:** the Ubuntu package set used by Bloom's managed rootless Docker installation. Only
  reviewed package versions are upgraded, with package and service checks repeated before applying.
  The plan discloses container and Docker service restarts. This is not a blanket APT upgrade or
  support for every Docker installation. Package changes do not have automatic package rollback.

The Mac checks for updates in the background while it is connected: once shortly after each
connection, then every six hours, or twenty minutes after a request that failed. It sends the same
`inspect` the Updates screen does, so the supervisor (whose GitHub lookup is cached for fifteen
minutes) remains the only thing that talks to GitHub. When an update exists, the sidebar's server
heading shows a small download arrow and Server Settings badges Updates and lists the new versions
with **Review Update…**. Nothing is ever installed without that review. Checks need maintenance
access, so a Mac without the key shows nothing. `ServerUpdateCheckSchedule` and
`ServerUpdateNotice` in BloomClient hold these decisions, for iPhone and iPad to share.

Releases publish `bloom-server-linux-x86_64.json` beside the package. When a release has one, the
supervisor reads it before offering the release: a different client protocol, a different
maintenance protocol, another architecture or a newer glibc than the server has marks the release
`incompatible` with the reason, instead of offering an update that would be refused after its
download. A release with a newer protocol names the way forward: update Bloom on the Mac, then use
**Update Server…**, which installs the server that app includes. Older releases without the
description are offered as before, and every rule is still checked on the downloaded manifest.

Maintenance requires `diagnostics.maintenanceManagement: true` and a separate administrator key.
The wizard retains the key in this Mac's Keychain and installs only its SHA-256 digest on the
server, and its Finish step says so and offers **Copy Key for Another Device…**. Other clients
enter the maintenance key in Updates; normal workspace authentication alone cannot authorise
maintenance. A client without the key but with administrator SSH access can choose **Issue New
Key…** in Updates instead. After a confirmation that other devices will need the new key, it
generates a key, sends only its digest over SSH (`install-bloom-server.py
--replace-maintenance-key`), saves the key in its Keychain, and the running supervisor adopts the
new digest without restarting. The [maintenance protocol](SERVER-MAINTENANCE.md) documents access,
plans, phases, idempotency, logs and shared client behaviour.

On older SSH servers, **Set Up Server Updates…** keeps the administrator checks and installation
inside Updates. Review the proposed `root@host` address and installation location, then confirm
**Update and Reconnect**. Bloom verifies the package and client key before disconnecting, checks
for active work, stops the managed service, installs and starts it, then reconnects. If installation
fails, it attempts to restart the service without repeating installation. Keep the Mac connected
during this initial installation of the maintenance service.

Administrator checks display the installed package version alongside the exact version included
with the Mac app. Equal package digests identify the same build; development hashes are not
ordered as release numbers. The review action is disabled when the package is already current,
unless the maintenance service still needs installing. Published-version checks are available
through the managed components list, which keeps unavailable versions distinct from up-to-date
ones. Bootstrap completion shows a separate result with copyable output, including when the
package was installed but startup or reconnection still needs attention.

When disconnected, Updates offers **Reconnect**, **Start Server…** and **Update Server…**.
Starting verifies the existing managed installation without replacing packages or project data.
Automatic connection retries resume after failures; a deliberate disconnect or change of server
prevents a completed update from reconnecting the wrong profile. Administrator checks must match
the saved SSH host and data directory. HTTPS-only legacy profiles need a corresponding SSH
connection before this initial migration; Bloom does not infer administrator access from a web URL.

The root-owned Python supervisor and support modules live in `/usr/local/libexec`; protected
metadata, recovery files and verified releases live in `/var/lib/bloom-maintenance/bloom-server`.
Project data remains under the Bloom account. These privileged Python modules are installed and
updated through the administrator installer. A runtime update does not replace the supervisor
or its privileged support code.

An accepted job is not a successful update. `rolledBack`, `failed` and `interrupted` retain their
actual outcomes and recovery details. **Recover Update** resumes an interrupted job's saved
checkpoint without rerunning npm or APT installation. Clients poll first after a lost response;
an explicit retry reuses the original request UUID. They never automatically resubmit an install.

Runtime updates come from the Bloom releases themselves: each one attaches the server package, built
and checked as [RELEASING.md](../RELEASING.md#bloom-server) describes. The supervisor reads the latest
stable release of `spatie/bloom` and offers it when its tag is newer than the installed version.
Prereleases are never offered, and neither is an older version. A server may take up to fifteen
minutes to notice a new release; reviewing an update always checks again, and the plan pins the
exact asset and its GitHub SHA-256 digest. The package manifest must name that version, `x86_64`,
maintenance protocol 1 and the wire protocol the supervisor was installed for. A release with a
different protocol version fails before anything is replaced, and such a server moves through
**Update Server…** instead, which reinstalls the supervisor with it. Development bootstrap uses a
matching packaged server payload; client builds alone do not install or enable the supervisor on an
existing server.

On servers without the maintenance capability, the Mac app also offers **Use Legacy SSH Updates…**
for AI tools. This older path requires the SSH connection to remain open and supports its existing
npm and native Claude update commands. It has no durable server job or maintenance handover; do
not confuse its process activity check with the supervised maintenance lock. Its regression suite
is `python3 Tools/test-server-tool-updates.py`.
