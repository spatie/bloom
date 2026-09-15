# Reliability and shared-client boundaries

Bloom's iPhone and iPad interface is one adaptive UIKit app. It is not two separate clients.
The Mac app uses AppKit and SwiftUI, while both Apple targets share platform-neutral feature
logic and selected presentation in the packages below. Sharing everything that imports a UI
framework would lose useful native behaviour; sharing the rules behind those views prevents drift.

## Ownership and patterns

| Boundary | Existing approach | Why it belongs here |
| --- | --- | --- |
| Server runtime and agent sessions | Actors with typed commands, lifecycle states and Store transactions | One owner serialises in-memory state; transactions protect persisted invariants across suspension points. |
| Workspace mutation admission | `ServerWorkspaceAdmissions` tracks open, closing and closed states with scoped tickets | RPC and MCP mutations participate in the same archive drain, including agent creation that was already awaiting discovery. |
| Durable mutations | Request IDs and recorded pending/completed outcomes | A retry retains its identity. An uncertain side effect is inspected rather than executed again automatically. |
| RPC lifetime | `ServerConnections` owns sockets and request tasks with bounded admission | Shutdown closes idle clients and drains work before releasing the data-directory lock. |
| Socket output | Serial writes with bounded inactivity and an async adapter | Slow readers cannot hold the close lock or block the cooperative executor while waiting for buffer space. |
| Review work | `ServerReviewCache` owns watchers, workers and shutdown | Closing refuses new work, cancels queued waiters and cleans up work that resumes after an await. |
| Transport handshake | `RemoteWireSession` coalesces negotiation with cancellation per caller | One cancelled reader does not strand itself or cancel another client's shared handshake. Only negotiation is retried automatically. |
| SSH connection | Connection, authentication, channel acceptance and request deadlines share one lifetime | Cancellation can close a connecting channel; command rejection becomes an immediate failure. |
| Saved server selection | Typed connection profiles and candidate authentication | A failed sign-in cannot relabel an existing live connection as a different server. Profiles preserve the previous address and trust-store reference. |
| Workspace creation and command recovery | Typed contexts, pending commands and acknowledgement state | Native forms use the same choices and keep uncertain command identities. |

An action class is useful when it encapsulates a coherent operation or policy. Swift structs,
enums, actor methods and small services provide the same separation without requiring one class
per button. State machines are most useful around asynchronous transitions: connecting, authenticating,
starting or archiving a workspace, delivering a prompt, and acknowledging a mutation. Pure formatters,
file labels and native menus do not need a state-machine framework.

## Shared code

`BloomCore` contains the canonical agent runners and output parsers, used by local Mac execution
and Bloom Server. Remote clients receive normalised conversation records rather than maintaining
another parser for each agent's raw output.

`BloomClient` contains wire negotiation, typed service helpers, creation contexts, composer values,
review state and caches, transcript projection, tool presentation, command recovery, draft handling,
archive safety reports and hazards, terminal contracts, and leased UI bridge state. Mac code aliases
shared value types where existing callers need the old names.

Mac drafts now reuse `ConversationDraftStore` with an endpoint scope. Legacy UUID-only drafts are
imported only for their original saved connection, and a late upload retains its originating server.
The shared `WorkspaceNote` rules require a known loaded baseline before saving. The iOS notes editor
stays read-only after a failed initial read and offers retry instead of saving a blank document.

`BloomSSH` supplies the native SSH transport used by the mobile app. `BloomUI` contains reusable
conversation, markdown, tool-card and diff presentation. AppKit and UIKit retain native selection,
editing, focus, menus, panes and lifecycle integration.

The protocol audit found that the portable catalogue/transcript DTOs were dropping archived workspaces,
queued prompts and permission decisions that the server already sent. These fields now survive decoding,
with defaults for older snapshots. Archive confirmation uses the same safety value types as the Mac,
requires the complete safety report, and rejects a response for another workspace.

## Protocol completeness

The current protocol is usable by non-Swift clients, but it is not yet a complete generated SDK contract.
The generator checks all operation names and argument inventories against Swift. Production encoding
vectors also validate concrete wire values, including queue, archive and restore behaviour.

Some records still use the permissive `DomainRecord` schema, and production vectors do not exercise every
operation/result combination. This means the schema cannot generate fully typed clients for every feature
or detect every field-level change. The exact limitations and authoritative Swift definitions are linked
from [the protocol guide](SERVER-PROTOCOL.md).

The next boundary to extract is a transport-only protocol module for operation, result and DTO definitions,
with host adapters in BloomCore. The current generic `RemoteCommand.operation` and string-built helper
names remain a source of drift. Completing the schema and generating language clients should follow that
single source of truth, rather than creating a third handwritten model layer.

## Remaining design work

- Persist and restore mobile pane layouts and terminal identities. A shell surviving disconnect is not
  enough if reopening the mobile app cannot restore the tab that attaches to it.
- Consolidate remaining conversation orchestration, including queue/permission presentation and recovery,
  through shared stores while preserving each platform's native lifecycle.
- Bound durable receipt storage without making an old mutation replayable. The existing journal retains
  whole requests and replies indefinitely; request fingerprints and non-replay tombstones need a deliberate
  migration and retention policy before large payloads can be compacted safely.
- Keep setup and provisioning separate from buying infrastructure. The Add Server wizard configures an
  existing Ubuntu machine supplied by any hosting provider.

The Laravel example still needs PostgreSQL, Redis, web serving, queue workers, WebSockets and frontend
assets. Its project helper consolidation reduces indirection, not those application requirements. A
versioned Bloom-managed environment preset could remove more duplicated project plumbing, but it needs
a stable configuration and upgrade contract before moving that behaviour out of repositories.
