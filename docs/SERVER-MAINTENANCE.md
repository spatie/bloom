# Supervised server maintenance

Maintenance is a capability-gated extension to Bloom wire protocol 14. Its standalone payload
contract is [maintenance-v1.schema.json](../Protocol/maintenance-v1.schema.json), also included
in [the protocol 14 envelope schema](../Protocol/bloom-v14.schema.json).

The supervisor owns update plans and jobs independently of the agent runtime. SSH and HTTPS
clients use the same maintenance requests. The supervised endpoint must continue serving hello,
diagnostics and maintenance status while its runtime is restarting or unavailable. A plain
runtime without a supervisor reports maintenance as unsupported.

This document describes the client contract. Which components can update, their installation
and rollback rules, and the durable job execution belong to the supervisor implementation.
A successful client build is not evidence that a particular server installation supports it.

## Capability and authentication

Read diagnostics first. `maintenanceManagement: true` means the endpoint supports this contract.
A missing or false value means unsupported. Clients must not send maintenance credentials to
older endpoints as a feature probe. This addition does not change `BloomWire.version` or require
older clients to understand the new operation.

Normal connection authentication grants access to the workspace API. Maintenance requires a
separate credential supplied in the request payload. Store it in the platform Keychain or an
equivalent protected credential store, scoped to the verified server identity. The shared client
session retains it only in memory. Do not put it in preferences, URLs, logs, analytics, clipboard
reports or the normal durable command outbox.

Unauthenticated `inspect` returns only safe component information, with `authorized: false`.
Preparing, starting, reading job status, cancelling and recovering require the maintenance credential.
Authentication failures use code `unauthorized`; they must never silently fall back to a
privileged SSH command or another connection route.

The supervisor must authenticate every request before looking up an idempotency result. Strip
credentials before persisting or hashing a mutation's intent. A revoked credential must not
retrieve a previously authorised result merely by replaying its UUID.

The supervisor compares credentials with the digest in its protected configuration and re-reads
that file when it changes. An administrator replaces the digest with
`install-bloom-server.py --replace-maintenance-key --maintenance-key-sha256 <digest>` over SSH, which
rewrites only that field of a completed supervised installation. The next request is checked
against the new digest, no service restarts, and the previous key stops working. A configuration
that can no longer be read safely authorises nobody.

## Request envelope

`version` is the app wire version, `BloomWire.version`, not the maintenance protocol. The
supervisor accepts any positive integer, replies with the same one, and leaves wire compatibility
to the runtime it forwards other operations to.

```json
{
  "version": 15,
  "id": "e784db85-ded5-4f25-a066-07ecb2b611a1",
  "operation": {
    "maintenance": {
      "_0": {
        "action": "prepare",
        "credential": "<maintenance credential>",
        "component": "server"
      }
    }
  }
}
```

All payload fields are flat. Optional fields may be omitted or null.

| Action | Inputs | Result |
| --- | --- | --- |
| `inspect` | Optional credential | Safe components; authorised clients may also recover job history. |
| `prepare` | Credential and component | A reviewed, expiring plan with an exact target version and restart disclosure. |
| `start` | Credential, planID, mode | A durable job. Mode is `now` or `whenIdle`; the server validates whether the choice is permitted. |
| `status` | Credential, optional jobID and afterSequence | Job phases and logs. No mutation is started. |
| `cancel` | Credential and jobID | Cancellation requested only while the server allows it. |
| `recover` | Credential and jobID | Resume checkpoint recovery for an interrupted job. Never rerun package installation. |

Components are `server`, `claude`, `codex` and `docker`. An advertised component can still have
`canUpdate: false`, for example when its installer is managed externally. Show its explanation
instead of inventing another update command.

The outer request UUID is the mutation's idempotency key. After transport loss, inspect status
first. If a manual retry is necessary, reuse the original UUID, action, plan, mode and job ID.
Do not automatically send a new start request. The credential may be reloaded from protected
storage; it is not part of the durable operation identity.

## Response

Replies use `result.maintenance._0` with these fields:

- `authorized`: whether this request has maintenance access.
- `components`: component ID, title, installed and available versions, canUpdate and detail, and
  optionally `incompatible`.
- `plan`: optional ID, component, fromVersion, targetVersion, summary, restarts and expiresAt.
- `jobs`: job records, including component, plan ID, target, phase, log cursor and cancellation permission.
- `error`: optional code, message and recovery. Errors do not imply that an earlier job stopped.

`incompatible: true` marks a newer release this installation must not update to in place. Its
`canUpdate` is false and its `detail` gives the reason and the next step, usually updating the Mac
app and running **Update Server…** over administrator SSH. `prepare` for it fails with
`incompatible_release`, and no package is downloaded. The supervisor decides this from the
release's published `bloom-server-linux-x86_64.json` (`protocolVersion`,
`maintenanceProtocolVersion`, `architecture`, `glibc`), fetched through the same asset download as
the package. A description whose `name`, `tag` or `sha256` disagrees with the release makes it
unavailable. Without a readable description the release is offered as before, and the downloaded
manifest is checked either way. Clients that predate the field ignore it and still see
`canUpdate: false` with the reason.

Dates use ISO 8601 strings. `restarts` is a list of descriptions users review before starting.
An expired or unparseable plan expiry cannot be confirmed by the shared client. The supervisor
must independently enforce expiry and revalidate installation state when accepting a start.

A job's `nextSequence` is a per-job cursor to echo unchanged as `afterSequence`. Treat it as an
opaque cursor, not an array index. Log entries have `sequence` and `message`; clients merge
incremental responses by sequence without duplicating previous output. Without a job ID, the
request asks for the supervisor's job history rather than applying a single job's cursor globally.

## Lifecycle and truthful outcomes

Active phases are `queued`, `waiting`, `downloading`, `installing`, `restarting` and `verifying`.
Terminal phases are `succeeded`, `failed`, `rolledBack`, `cancelled` and `interrupted`.

Only `succeeded` is success. `rolledBack` means the previous version was restored and needs
attention; it is not a successful update to the requested target. A reconnect, accepted start,
new process ID or closed log stream is not proof of success. Keep showing the recorded job
until its authoritative phase is terminal.

`canCancel` is the server's current permission for that job. A client may offer cancellation
only while that value is true and the phase is active. The supervisor checks again when the
request arrives. Closing a view, cancelling a status read or locking local maintenance access
must not cancel a server job.

## Server releases

For the `server` component, the available version is the latest stable GitHub release of
`spatie/bloom` carrying `bloom-server-linux-x86_64.tar.gz`, when its tag is newer than the installed
version. Every Bloom release attaches one; [RELEASING.md](../RELEASING.md#bloom-server) describes how
it is built and verified. When nothing is offered, `detail` carries the supervisor's reason, such as
a release without a server package or an unreachable GitHub; show it rather than "up to date".

A `prepare` looks at GitHub again and pins the asset ID and SHA-256 digest into the plan. The job
downloads exactly that asset and fails with `checksum_mismatch`, `incompatible_release` or
`release_version_mismatch`, before the running release is touched, when the bytes, the manifest's
protocol or its version disagree with the plan. A package whose wire protocol is older than the
installed release's, or which needs another maintenance protocol, is refused this way. A newer
wire protocol installs in place; a maintenance protocol change reaches a server through the
administrator installer instead. Startup verification failures after installation end in `rolledBack`.

### Retained releases and job history

Each server release is extracted once into the supervisor's `releases/`, in a directory named by
its package's SHA-256, of about 80 MB. Once an update commits, which is the point after which its
rollback can no longer be needed, the supervisor removes every release directory except three: the
running release, the release it replaced, and the release the supervisor's configuration names.
The last is there because the administrator installer writes that configuration, an update never
rewrites it, and the supervisor will not start without its executable. `current.json` records the
replaced release as `previous`, and a rollback restores that pointer with its release, so the
restored release and its predecessor are both kept by the next removal.

Nothing is removed while a transaction checkpoint or an unfinished job exists, and a rollback or
a failed update removes nothing. A candidate that rolled back stays until the next successful
update, which may reuse it. Only real directories directly inside `releases/` with a SHA-256 name
are considered; a symbolic link is never followed or removed, and nothing happens when the running
release is not inside `releases/`. Each removed release is written to the job's log. A failure to
remove one is logged too and does not change the job's outcome.

The administrator installer applies the same rule once an installation has started successfully,
to the protected releases and to the Bloom account's own `releases/` beside `current`, where the
package it replaced is kept in the installation marker as `previousSHA256`. Optional browser tools
under `/opt/bloom-browser/releases` keep the verified version and the one it replaced, recorded as
`previousRelease` in its configuration. `--uninstall` removes all of these directories, as before.

Job history keeps the newest 20 jobs. Older finished jobs are deleted with their logs and recovery
requests, except the newest job of each component, any job that has not finished, the job a
transaction checkpoint names, and any job whose plan has not yet expired. A status request for a
deleted job answers `job_missing`, and a replayed start for one fails with `plan_missing` rather
than starting another update. Expired plans that no kept job refers to are deleted as well.

## Shared Apple client

`ServerMaintenanceSession` in BloomClient owns authentication state, plan review, mutation
identity, job reconciliation and log merging. UIKit and SwiftUI supply the normal RemoteRequesting
client and a protected credential, then render its observable state. Create a new session when
the verified server identity changes. `refresh` recovers history; visible panels can call `poll`
every few seconds while jobs remain active or a mutation's response is unconfirmed.

Clients may read availability in the background with `inspect` alone, never `prepare` or `start`.
`ServerUpdateCheckSchedule` decides when: at once for a new connection, then after six hours, or
after twenty minutes when the request failed, and never while the session is busy.
`ServerUpdateNotice` decides whether to say anything: only with maintenance access, never during
an active job, and not for a version the latest job already installed.

The session never retries a mutation automatically. `retryPendingMutation` is an explicit user
action. A recovered job with the same plan ID resolves an unconfirmed start without sending it
again. `discardPlan` dismisses a review; `clearCredential` locks the local panel while server jobs
continue. Neither method deletes server records or modifies server access grants.

## Validation

Shared tests cover Codable round trips, credential-safe descriptions, capability rejection,
plan expiry, rollback classification, exact-ID manual retries, status reconciliation and
incremental log merging. `ServerMaintenanceWireTests` verifies that unsupported servers never
receive the credential-bearing maintenance request. The fixture export uses production Swift
Codable types, with test-only credentials:

`Tools/maintenance-supervisor-smoke.py` runs the supervisor as root in a disposable container
against a local HTTPS stand-in for GitHub (reached through `/etc/hosts` and a throwaway certificate
authority), so release lookup, the release description, redirects, digests and downloads use the
production code. It covers a verified update, a broken release that rolls back with its database,
a release refused from its description before download, and an update whose requesting client
disconnects mid download, finishing and then observed by a new connection.

```sh
BLOOM_MAINTENANCE_VECTORS_PATH=/tmp/bloom-maintenance-vectors.json \
  swift test --package-path Packages/BloomClient --filter ServerMaintenance
python3 Protocol/verify-maintenance.py /tmp/bloom-maintenance-vectors.json
```

### Interrupted update recovery

Offer **Recover Update** only for a job in `interrupted`. This is an explicit authenticated
mutation with the same UUID rules as `start`. The server resumes its saved recovery checkpoint,
including restoring a server release or checking a tool outcome. It does not start a new npm,
APT or Docker package installation. Normal inspection and status polling never trigger recovery.

The acceptance response moves the job to `restarting`. Resume polling while its recovery
worker runs. If the response is lost, poll the existing job. A final phase other than
`interrupted` confirms recovery completed. Otherwise an explicit retry reuses the original action, job ID and request
UUID. Keep displaying the server's precise failure and recovery instructions if it cannot
complete safely. A recovered update may be `failed` or `rolledBack`; recovery is not evidence
that the requested update succeeded.
