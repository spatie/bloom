# Shared clients and a public Bloom protocol

Status and direction, 10 September 2026. Shared review state, composer choices, transcript/review content and native iPad panes are implemented on this branch. The current wire contract is documented in [SERVER-PROTOCOL.md](SERVER-PROTOCOL.md), with schemas and an executable Python client under `Protocol/`. Generated application DTOs, a new public envelope and full feature parity remain future work.

Keep one repository and one set of feature rules. Share reusable presentation between Apple apps, with native navigation, editing, tables, menus, browser and window behaviour. A web client should consume the same server capabilities through a generated TypeScript client; it needs its own web presentation.

Apple explicitly supports local packages for modular code in one repository. Our existing packages are a good foundation; there is no reason to introduce separate repositories for every app or feature. [Apple's local-package guidance](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages)

| Boundary | Responsibility |
| --- | --- |
| Protocol schemas and `BloomProtocol` | Stable wire records, operations, results, events, error codes and capabilities. No database, process or UI types. |
| `BloomClient` | Shared feature stores, typed service interfaces, connection/retry policy, durable command intentions, transcript merging and revision caches. |
| `BloomUI` | Shared message, markdown, diff, file-label and other reusable content components. Platform typography and interaction adapters remain injectable. |
| Mac and iOS targets | Native navigation, panes, text editing, keyboard/focus, drag and drop, sheets, menus, lifecycle and platform integrations. |
| Bloom runtime | Authoritative projects, workspaces, sessions, agents, permissions, files, command receipts and process execution. |

`BloomProtocol` is a proposed lower-level target. Server code should eventually depend on it instead of importing an entire client module to get wire types. Keep feature stores grouped inside BloomClient initially; add further modules when a dependency boundary earns them.

```mermaid
flowchart LR
    Mac[Native Mac app] --> Features[Shared feature stores]
    iOS[Native iPhone / iPad app] --> Features
    Mac --> UI[Shared BloomUI content]
    iOS --> UI
    Features --> Service[Typed workspace service]
    Service --> Local[Local runtime adapter]
    Service --> Remote[SSH / HTTPS adapter]
    Remote --> Server[Bloom Server]
    Web[Web or third-party client] --> SDK[Generated language client]
    SDK --> Server
```

A local workspace must continue to work without a remote server, account or network round trip. Its in-process service adapter should satisfy the same capability interfaces as the remote adapter. Native views should not branch repeatedly on whether their execution host is local or remote.

Review state is now shared. `WorkspaceReviewStore` owns revision invalidation, coalesced reads, scope changes, cancellation, errors and per-file patch caching. `ServerReviewModel` and `MobileWorkspaceReview` adapt it to each app. Mac keeps its existing `DiffView` patch loader, so the adapter does not duplicate those reads. Mobile diff loads are limited to two at once; its cache retains visible sections and bounds offscreen entries. The pure changed-file tree, compressed folder chains and fuzzy filtering also live in BloomClient.

Composer values and decisions now live in BloomClient: controls, backend/model identity, model catalogues, supported reasoning levels, permission vocabulary, output styles and context choices. Mac's native picker and the iOS native option form consume those same decisions. `RemoteComposerStore` loads acknowledged server settings and preserves the command ID when an uncertain save is retried. Changing agent backends opens the session created by the server instead of continuing to send into the old conversation. Codex fast mode is hidden because the runner does not implement it.

Creation remains the next extraction. iOS still walks raw JSON in `RemoteWorkspaceService.workspaceCommand` and exposes fewer branch, attachment and start-mode choices than Mac. Its create form now accurately requires a prompt. Move typed creation choices and validation behind the shared service before expanding both native forms.

Then consolidate conversation state. Shared markdown cannot make queue controls, approvals or tool results appear automatically. `RemoteTranscript` currently omits some of the server's queue/permission projections, and `RemoteMessage.text` flattens rich payloads. A shared conversation store should expose typed turns, tools, queued messages, approval requests and connection states. Each shell renders the capabilities it supports and explains unavailable ones.

Command recovery belongs in the shared layer too. iOS persists uncertain message sends, but creation intentions are still held in memory; Mac also has in-memory uncertain-request state. Keep a durable command identity and explicit pending, acknowledged, rejected or unknown outcome. A crash between a server side effect and its receipt remains uncertain. Neither UUIDs nor retries promise exactly-once execution.

For external clients, publish a real contract rather than requiring people to read Swift enums. The current protocol is already ordinary JSON over SSH and HTTPS, so other languages can use it. Its weaknesses are the implicit Swift-associated-value shapes such as `_0`, opaque/base64 payloads, string-only failures, and limited wire-version negotiation (the Apple client now knows v12 and v13). That is not a stable public SDK boundary yet.

Use a canonical, versioned JSON Schema description for commands, replies and events. Give every operation an explicit name and named fields, document nullability, timestamp formats, safe numeric ranges and path semantics, and define structured errors. The same operations and handlers must serve SSH and HTTPS. There is no need for a second REST implementation with separate behaviour.

Document the HTTPS binding with OpenAPI 3.1 and references to those schemas. OpenAPI describes HTTP, not SSH framing. Apple provides a generator for Swift HTTP clients/server interfaces, and currently lists 3.0/3.1 support with preliminary 3.2 support. Start with a small generated Swift and TypeScript client covering catalogue, changes and one mutation before choosing the final generator configuration. A single generic RPC route may still need a thin typed service wrapper; generation does not produce business rules or native UI. [OpenAPI](https://spec.openapis.org/oas/v3.1.2.html), [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator)

Do not label the existing wire format JSON-RPC 2.0: it does not implement that envelope. If we choose that standard during a public-wire migration, OpenRPC is the corresponding method-description standard. That is an explicit migration decision, not a prerequisite for documenting today's protocol. [JSON-RPC 2.0](https://www.jsonrpc.org/specification), [OpenRPC](https://spec.open-rpc.org/)

The contract must cover behaviour as well as shapes:

- A capability handshake and documented compatibility window, so an additive feature does not require updating every client and server at once.
- Durable command identities, request correlation, receipt lookup and unknown-outcome recovery. Retrying a different payload under an existing command identity remains an error.
- Structured errors with stable codes, user-facing messages and actionable details. A generic retryable flag is insufficient after an uncertain mutation.
- Incremental events with cursors, ordering, replay and an expired-cursor recovery path. Define the event records once before adding another streaming transport.
- Revision-aware patches, bounded reads, cancellation, pagination and request limits for large workspaces.
- Authentication and server-side authorisation for every operation and workspace. Schema generation does not implement access control.

A browser cannot use the native SSH transport directly. It should connect through authenticated HTTPS. Prefer a same-origin web deployment initially and deliberately define browser sessions, CSRF/origin checks and reconnect behaviour. Keep agent-control credentials separate from workspace preview origins, as the existing gateway already requires.

Roll this out incrementally. Continue from the shared review and composer stores into creation state, keeping both Apple clients building in each change. Maintain the current v13 wire examples and their behaviour in contract tests. Then add generated wire types and the explicit public envelope behind a compatibility adapter to the existing runtime. Keep legacy clients working during a documented transition; do not replace v13 silently.

For each feature, review the server contract, shared state and presentation independently. Add a parity row for Mac local, Mac remote, iPhone and iPad, with deliberate unsupported cases. Shared tests prove feature behaviour; native smoke tests prove each shell exposes it. Adding a reusable component can reach both Apple apps automatically. A new Mac window, terminal integration or platform permission still needs an intentional mobile counterpart.
