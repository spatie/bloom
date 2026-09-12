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
Preparing, starting, reading job status and cancelling require the maintenance credential.
Authentication failures use code `unauthorized`; they must never silently fall back to a
privileged SSH command or another connection route.

The supervisor must authenticate every request before looking up an idempotency result. Strip
credentials before persisting or hashing a mutation's intent. A revoked credential must not
retrieve a previously authorised result merely by replaying its UUID.

## Request envelope

```json
{
  "version": 14,
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
- `components`: component ID, title, installed and available versions, canUpdate and detail.
- `plan`: optional ID, component, fromVersion, targetVersion, summary, restarts and expiresAt.
- `jobs`: job records, including component, plan ID, target, phase, log cursor and cancellation permission.
- `error`: optional code, message and recovery. Errors do not imply that an earlier job stopped.

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

## Shared Apple client

`ServerMaintenanceSession` in BloomClient owns authentication state, plan review, mutation
identity, job reconciliation and log merging. UIKit and SwiftUI supply the normal RemoteRequesting
client and a protected credential, then render its observable state. Create a new session when
the verified server identity changes. `refresh` recovers history; visible panels can call `poll`
every few seconds while jobs remain active or a mutation's response is unconfirmed.

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

```sh
BLOOM_MAINTENANCE_VECTORS_PATH=/tmp/bloom-maintenance-vectors.json \
  swift test --package-path Packages/BloomClient --filter ServerMaintenance
python3 Protocol/verify-maintenance.py /tmp/bloom-maintenance-vectors.json
```
