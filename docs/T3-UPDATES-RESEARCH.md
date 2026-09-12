# T3 update architecture and implications for Bloom

Reviewed 12 September 2026 at T3 commit
[`a43f9b45`](https://github.com/pingdotgg/t3code/tree/a43f9b45ae85caf37e0be8270ad3d27365ece2bd).
This is inspection of production source and test cases. We did not execute T3's updater,
install its packages, or change the Bloom test server during this investigation.

## Server replacement is owned by a stable launcher

T3's systemd/launchd service runs a small launcher, which runs the selected server as its child.
The child requests replacement through inherited IPC. The launcher owns durable service state;
the remote client does not rewrite the service definition. A foreground CLI server cannot
self-update. The launcher itself can require a separate local service update.
[Architecture][architecture], [capability and installation checks][self-update]

The replacement sequence is concrete:

1. Install an exact `t3@version` into staging, run preflight, then publish a version directory.
   The runtime is retained locally, so a later reboot does not depend on npm or a moving tag.
   The completion marker is written after installation and validation, not merely because an
   entry file exists. Preflight currently checks launcher protocol compatibility; its database
   path parameter does not mean it validates database migrations in advance.
   [Pinned installation][pinned], [preflight][preflight]
2. The launcher assigns an update ID and persists the pending replacement before acknowledging
   it. State writes use a temporary file, atomic replacement, file fsync and directory fsync.
   It refuses concurrent pending replacements and non-newer target versions.
   [State writes][state-writes], [handoff][handoff]
3. After stopping the old child, snapshot SQLite's database, WAL and shared-memory files once.
   A restarted launcher must not overwrite that original snapshot with a failed trial's data.
   [Backup and restore][database]
4. Start the target as a trial. Dependencies, migrations, HTTP binding and parked background
   tasks must be ready before the child reports `prepared`. The launcher durably commits the
   version before the runtime accepts ordinary commands and publishes ready.
   [Activation boundary][activation], [commit][commit]
5. A failed or timed-out trial restores the database and old runtime. A durable restore marker
   makes an interrupted restoration resume before either runtime is booted. The trial timeout
   is 120 seconds. After commit, the new runtime is authoritative and ordinary service restart
   policy applies; this is not an indefinite rollback guarantee.
   [Recovery][recovery], [trial rollback][rollback]

The rollback boundary is SQLite. Attachments, workspaces and arbitrary filesystem changes are
not included. This is why candidate startup must not execute ordinary workspace activity before
the commit boundary. [Explicit limitations][architecture]

## What clients must verify

The server returns the accepted update ID. After reconnecting, the ready event includes the
outcome, and clients must correlate it with that ID and expected version. Reconnecting to the
old runtime after rollback must not show an update-success message. The current persisted
launcher document contains an active version and one update record; it is not a full maintenance
history or general durable log service.
[Ready event][activation], [state contract][contract], [client acknowledgement][architecture]

Desktop-hosted servers have a separate prepare-token/commit handoff because replacing the host
app stops its backend. This avoids shutting down before the requesting client receives the
successful preparation response. [Desktop acknowledgement][architecture]

## User-facing actions and protocol

Web and desktop show update notices in conversations and Connections settings. Advertised
capabilities determine whether the action updates a background service, updates the host's
desktop app, or copies a manual command. There is also an Update All action for eligible
environments. Service synchronisation selects the requesting client's exact version, not
unconditionally the latest release. Desktop-host replacement follows that host's configured
updater channel instead. [User guide][guide], [update actions][actions]

The shared client runtime keeps update state outside individual views. It shows Downloading
and Restarting, uses a bounded four-minute reconnect window, and validates update ID, committed
outcome and target version. Its reconnect pacing during a known update is approximately one
second, rather than ordinary exponential backoff. This is special update recovery, not a
reason to retry arbitrary authentication or permission failures forever.
[Shared client state and recovery][client]

The update RPC requires `orchestration:operate`, which is a broad environment-operation scope,
not a distinct update-administrator permission. The protocol can be consumed by other clients,
but this bounded review did not establish a remote-server update button in the mobile app.
Mobile environment editing changes a label/address; mobile store/OTA updating is separate.
[Authorisation][authorisation], [mobile guide][guide], [mobile environment editing][mobile]

Supported-thread continuation after restart is optional and off by default. It depends on
saved provider resume state, and terminal commands can still be interrupted. Do not describe
this as waiting until idle or preserving uninterrupted work. [Continuation limits][guide]

## Claude, Codex and other provider tools

T3's `server.updateProvider` RPC runs maintenance on the execution server, with shared advisory
and result DTOs. It detects the owning installer, supports a broader set of installers than
Bloom (including native vendor tools, npm, Bun, pnpm and Homebrew), and leaves unknown ownership
manual-only. Latest-version checks respect what that installer can actually deliver. This
avoids reporting a Homebrew tool as outdated solely because npm has a newer release.
[Installer and version resolution][provider], [RPC][provider-rpc]

Maintenance is serialised by package-manager lock identity. The runner resolves ownership
again after acquiring that lock, bounds subprocess runtime/output, refreshes the tool after
installation and distinguishes verified success, unchanged versions and unverifiable results.
The locks are process-local semaphores, not OS-wide locks, and the provider action does not
accept a selected target version. Its npm path uses latest; native updaters choose their channel.
[Coordinator][provider-coordinator], [Runner][provider-runner]

No active-agent admission guard or old-binary rollback was found in the inspected complete
provider execution path. The duplicate-running guard concerns maintenance jobs, not running
AI turns. Keep Bloom's private-user filesystem checks and active-agent refusal, and strengthen
them with an atomic admission barrier rather than copying this omission.
[Runner][provider-runner], [provider RPC dispatch][provider-dispatch]

The inspected provider maintenance API does not update Docker, Node itself or operating-system
packages. Its guarantees should not be extended to those components. Tests cover changed
ownership, shared installer locks, cancellation, and exit-zero results where the provider is
missing or remains outdated. [Provider runner tests][provider-tests]

## What Bloom should adopt

Adopt the small launcher, exact-version staging, durable acceptance, trial activation gate,
database restoration marker, and outcome correlation. These are stronger foundations than a
client-owned SSH command followed by a reconnect spinner.

Keep Bloom's compiled Linux releases and existing installer rather than copying npm mechanics.
Add a verified release manifest and compatibility checks suited to independently released Mac,
iOS and web clients. Do not label a package verified merely because its version string matches.

Make "Update when idle" the ordinary path. An optional restart-and-resume mechanism is not the
same guarantee as leaving a running turn uninterrupted. Use a server-side admission barrier,
not a client-side process check with a race before installation.

Keep administrative maintenance permission distinct from ordinary workspace operation. A
supervisor is not a reason to give a coding agent a generic privileged command executor.
Docker/system package maintenance and project-container updates require separate adapters and
restart policies; the server runtime's database rollback cannot cover those operations.

For the public protocol, expose reviewed plans, idempotent job acceptance, resumable observations,
safe cancellation points and explicit terminal outcomes. A job that has been accepted must not
be resubmitted just because the initiating device missed a response.

## Relevant failure tests inspected

T3 checks contradictory persisted state, exact-version ordering, shutdown during recovery,
commit only after preparation, a trial returning the wrong update ID, restoration after a
migrating trial exits, and interruption during launcher handoff. These were read, not run.
[Launcher tests][launcher-tests], [self-update tests][self-update-tests]

[architecture]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/internals/server-updates.md
[self-update]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/cloud/selfUpdate.ts#L176-L320
[pinned]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/cloud/pinnedRuntime.ts#L92-L244
[preflight]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/cloud/servicePreflight.ts
[state-writes]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.ts#L183-L205
[handoff]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.ts#L454-L512
[database]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.ts#L98-L164
[activation]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serverRuntimeStartup.ts#L946-L987
[commit]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.ts#L514-L540
[recovery]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.ts#L354-L390
[rollback]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.ts#L542-L601
[contract]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/cloud/serviceProtocol.ts#L13-L59
[launcher-tests]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/serviceLauncher.test.ts
[self-update-tests]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/cloud/selfUpdate.test.ts
[guide]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/user/updating.md
[actions]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ServerUpdateAction.tsx#L91-L175
[client]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/packages/client-runtime/src/state/server.ts#L127-L215
[authorisation]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/auth/RpcAuthorization.ts#L23-L48
[mobile]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/mobile/src/features/settings/SettingsEnvironmentsRouteScreen.tsx#L26-L76
[provider]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/providerMaintenance.ts#L339-L721
[provider-rpc]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/packages/contracts/src/rpc.ts#L455-L459
[provider-coordinator]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/providerMaintenanceCommandCoordinator.ts#L15-L83
[provider-runner]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/providerMaintenanceRunner.ts#L301-L485
[provider-dispatch]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/ws.ts#L1859-L1866
[provider-tests]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/providerMaintenanceRunner.test.ts#L259-L845
