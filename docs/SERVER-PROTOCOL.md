# Bloom server protocol

This is the public client contract for Bloom Server protocol 14. A client can be written in any
language. It sends JSON requests to the owning server; it never opens the server's SQLite database.
The same operations serve macOS, iPhone, iPad and other clients.

The checked-in [JSON Schema](../Protocol/bloom-v14.schema.json) describes the envelopes, every
operation and nested action, and the review/transcript framing. The
[Python example](../Protocol/examples/bloom_client.py) uses the standard library and supports
SSH and HTTPS. It makes only read-only requests. No server deployment or Swift runtime is needed
on a non-Swift client.

The authoritative version is `BloomWire.version` in
[`RemoteCommand.swift`](../Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift).
[`ServerProtocol.swift`](../Sources/BloomCore/Server/ServerProtocol.swift) defines the host's
Codable request and result types. The schema generator verifies every case inventory and associated argument name against the
Swift source. This contract describes the existing wire format; it does not introduce a second API.

## Transport and authentication

### SSH

Connect with host-key verification and public-key authentication. On the server, execute:

```sh
/opt/bloom-server/current/bin/bloom-server connect --data-dir /var/lib/bloom
```

The executable and data directory are administrator-provided connection settings. The command
connects to the existing daemon. It does not start a competing daemon or acquire database ownership.
Use an exec channel without a PTY. Send one compact UTF-8 JSON request followed by LF on stdin;
read one JSON reply line on stdout. Keep stdin open until that reply arrives; EOF can close the
relay before the response. Keep diagnostic stderr separate. The simple example opens
one channel per request. A persistent stream must correlate replies by ID because concurrent
operations can complete out of order. Do not assume line order is request order.

Never accept an unknown or changed host key automatically. The native app pins the SHA-256 SSH
fingerprint; the Python example requires a previously trusted OpenSSH `known_hosts` entry.
SSH grants the authority of that server account, including executing agents and changing worktrees.

### HTTPS

Send `POST https://<api-origin>/v1/rpc`, with no query string:

```http
Content-Type: application/json
Accept: application/json
Authorization: Bearer <access-token>
```

The body is exactly the same JSON envelope, without needing a trailing LF. Success and application
failures both use HTTP 200 with a Bloom reply. The current gateway accepts protocols 12, 13 and 14. Older gateways that reject a newer hello before it reaches the runtime need a gateway update.
It rejects HTTP redirects in native clients so bearer credentials cannot move to another origin.
A custom client must also refuse redirects and verify TLS normally.

Public OAuth configuration is available from `GET /.well-known/bloom-auth`. Use authorisation
code flow with PKCE S256 through the system authentication browser and a registered native
redirect. There is no client secret in a native app. The gateway validates signed access tokens,
issuer, audience, expiry, configured scopes and an explicit subject/email allowlist. An ID token
is not an API access token. Opaque-token introspection is not implemented. See
[Gateway configuration](../Gateway/README.md) for the provider contract, revocation, proxy headers
and deployment requirements. Tokens belong in secure credential storage, not URLs or preferences.

The gateway's runtime Unix socket is an internal deployment boundary with full control authority.
The protocol does not currently offer separate per-method or per-workspace control permissions
within one runtime. Deploy separate runtimes/accounts when that isolation is required.

## JSON encoding

This is a tagged JSON protocol, not JSON-RPC 2.0. There is no `jsonrpc`, `method` or `params` field.

```json
{"version":14,"id":"00000000-0000-4000-8000-000000000001","operation":{"hello":{}}}
```

```json
{"version":14,"id":"00000000-0000-4000-8000-000000000001","result":{"hello":{"name":"example-server"}}}
```

Each request contains `version`, a UUID `id`, and exactly one operation tag. Each reply contains
`version`, the same UUID `id`, and exactly one result tag. Reject a mismatched reply ID before
interpreting its version or payload. UUID case is not significant. Repository, workspace, session,
delivery and terminal-tab IDs are plain JSON strings. Treat those strings as opaque identifiers;
do not require them to parse as UUIDs or reinterpret them as local paths.

Swift enum cases become objects with one key. A case with named associated fields puts those
fields inside the case object. An unnamed associated value uses `_0`. A case without a value
has an empty object. Nested enums repeat the same encoding:

```json
{"creation":{"_0":{"workspaceContext":{"_0":"repo-example"}}}}
```

```json
{"workspace":{"workspaceID":"workspace-example","action":{"writeFile":{"path":"README.md","text":"Hello\n","revision":"previous-hash"}}}}
```

```json
{"answer":{"sessionID":"session-example","requestID":"agent-question-id","answer":{"denyWithReason":{"message":"Keep the existing data.","endsTurn":false}}}}
```

These are operation objects, not complete request envelopes. A string-valued result looks like
`{"text":{"_0":"value"}}`; success without a payload is `{"accepted":{}}`.

Other encoding rules:

- Optional properties are usually omitted when absent. Decoders also accept JSON `null` for
  optional fields. Do not interpret an omitted optional field as an empty array or string.
- `Data` values are standard Base64 strings. This includes message `payload`, `pendingQuestions`,
  upload/attachment bytes and download `data`. Decode Base64 before interpreting nested JSON.
- Dates are JSON numbers counting seconds since `2001-01-01T00:00:00Z`, including fractional
  seconds. To obtain Unix seconds, add `978307200`. They are not ISO-8601 strings or milliseconds.
- Strings use normal JSON escaping. Newlines within strings must remain escaped on SSH streams.
- Message IDs are signed 64-bit integers. A JavaScript client should preserve integer precision
  when decoding values outside its safe integer range.
- Raw enums, including agent, permission mode, scope and session state, are strings. Discover
  available agents/models and valid composer choices from the server; do not duplicate defaults.
- JSON object ordering is not significant. Send only known request fields. Decode documented
  records while tolerating additional reply fields, so additive record data does not break a client.

## Version negotiation

Current clients support versions 14, 13 and 12. Version 14 adds the leased `uiBridge`; version 13 adds `diagnostics`; the existing workspace
operations retain their version-12 encoding. This is an explicit compatibility exception, not a
promise that any older or newer version is compatible.

1. Send a read-only version-14 `hello` with a fresh UUID.
2. Validate the reply ID. If the reply is version 14, require a successful `hello` with a `name`.
3. Only if the reply is version 12 or 13 and its result is exactly
   `{"failure":{"_0":"Incompatible Bloom server protocol. Update the client and server."}}`,
   resend that same hello ID with the version named by the reply.
4. Require a successful hello at that exact version. Pin it for this connection. Do not call
   `diagnostics` on version 12, or `uiBridge` below version 14.
5. Refuse all other version mismatches and reconnect after a server upgrade.

Never probe compatibility with a mutation. Never resend a mutation with a different wire version.
[`RemoteWireSession`](../Packages/BloomClient/Sources/BloomClient/RemoteWireSession.swift) is the
shared reference implementation. HTTPS gateways may reject a mismatched version with HTTP 400
before a Bloom reply; the current gateway does not implement a version-12/13 endpoint.

## State, polling and review

`catalogue` returns repositories, active workspaces, sessions and archived workspaces. The server
owns the canonical records and session lifetimes. Clients may cache display state and drafts,
then refresh server records after reconnecting or making a change.

For each session, call `transcript` with the last received `seq` as `afterSeq`. The response includes
up to 500 persisted messages after that sequence. Merge by message ID/sequence; keep paging if a
full page arrives. Advance the cursor only after storing the received messages. `streamingText`
is the entire current in-progress assistant text snapshot, not a delta to append. Replace it on
each poll and let persisted messages take over when the turn completes. `isBusy` is runtime state;
a transport disconnect is not proof that an agent stopped.

A transcript includes:

| Field | Meaning |
| --- | --- |
| `session` | Current session record, including agent, model, state and read position. |
| `messages` | Persisted message records with `id`, `sessionID`, `seq`, `kind`, Base64 `payload`, `createdAt`, and optional `durationMS`/`refID`. |
| `pendingQuestions` | Base64 JSON for pending agent permission/question requests. |
| `isBusy`, `streamingText` | Current runtime activity and incomplete assistant text. |
| `permissionDecisions` | Map of request/tool identifiers to recorded decisions. |
| `queuedPrompts` | Server-owned pending prompt deliveries; use their IDs to cancel. |
| `queueError` | Optional queue failure text, separate from an assistant turn failure. |

Message kinds currently include `user`, `assistantText`, `thinking`, `toolUse`, `toolResult`,
`permissionAsk`, `result`, `error`, `system`, `notice` and `crew`. Payloads retain agent-specific
JSON. A basic renderer can read `text`, `message`, or content blocks containing `text`, then fall
back to formatted JSON. A full renderer should preserve tool IDs, approval requests and structured
content rather than flatten everything into prose. Unknown message data should remain inspectable.

For changed files, prefer `reviewSnapshot` and `reviewPatch` over the older `changes` and `patch`:

- Fetch a snapshot first. `scope: "branch"` compares the workspace with its branch baseline;
  `"uncommitted"` compares current work with HEAD.
- Keep the returned opaque `revision`. Send it as `knownRevision` next time. An omitted/null
  `files` means the matching cached list is unchanged. `files: []` means there are no changes.
- `wait: true` waits up to 15 seconds for a changed revision. It is long polling, not SSE.
- Request patches for selected/visible files and cache them by revision. An omitted/null `patch`
  means that matching cached patch is unchanged. Do not discard the previous patch in that case.
- A changed-file row carries `path`, optional `oldPath`, change code (`A/M/D/R/C/?`), additions,
  deletions, `isBinary`, optional `contentRevision`, and `hasIncompleteStats`. Incomplete statistics
  must not be presented as verified zero-line changes.
- An all-files review is a client presentation over this list plus per-file patches. There is no
  separate monolithic all-files-review RPC. Fetching every patch after each keystroke defeats the cache.

`workspace.action.files` returns the tracked and non-ignored untracked relative paths. Build a
folder index locally. `file` returns UTF-8 `text`, the requested relative `path` and an opaque
`revision`. A later `writeFile` must carry that revision. A conflict requires rereading the file
and reconciling edits; do not overwrite with a guessed revision. Paths are resolved and checked on
the server against the selected worktree, including containment checks. Download binary files
through `workspace.action.download`.

### Common selection and composer records

Repository records expose `id`, `name`, server `path`, `defaultBranch`, `hidden` and `accent`.
Workspace records expose `id`, `repoID`, `name`, server `path`, `branch`, `baseBranch`, `state`,
`setupState`, `setupLog` and assigned app `port`. Session records expose `id`, optional `workspaceID`,
`title`, `model`, `effort`, `agentKind`, `permissionMode`, `state`, `createdAt` and `updatedAt`.
Use `workspaceID`/`repoID` relationships to build navigation; do not join by display names.
These records contain additional fields, including ordering, activity and usage statistics.

A composer state contains `controls`, `models`, `commands`, `styles` and optional `availableAgents`.
The complete `controls` object has these required fields:

| Field | JSON type | Meaning |
| --- | --- | --- |
| `model` | string | Model identifier, not its display label. |
| `effort` | string | Supported reasoning effort for the selected model. |
| `agentKind` | string | Agent backend (`claudeCode`, `codex`, `cursor`, `openCode`); availability is server-owned. |
| `permissionMode` | string | Backend-compatible mode (`auto`, `acceptEdits`, `autoReview`, `bypassPermissions`, `plan`). |
| `isFastMode` | bool | Fast mode preference. |
| `outputStyle` | string | Server output-style name. |
| `codexContextWindow` | integer | Codex context-window preference, including its server default sentinel. |
| `hasWorktree` | bool | Whether this conversation has a worktree. |

Preserve all fields when changing one picker. The client must not invent options when a server
has not advertised an available agent/model. `setComposer` can return `created` when the chosen
agent differs from the current conversation's agent: switch to the returned session instead of
assuming that the old session changed backend. Computed Swift convenience properties such as
`choices` are not additional JSON fields.

## Operation inventory

`M` means the runtime records a durable command ID for an operation that may change state. `R`
means it does not use mutation deduplication. An `R` operation can still refresh an internal cache
or read external tools. `mixed` depends on the nested action below. A failure result is possible
for every operation. Names and field names are case-sensitive.

| Operation | Fields inside case object | Successful result | Kind |
| --- | --- | --- | --- |
| `uiBridge` | `_0: UIBridgeOperation` | `uiBridge._0` | R |
| `hello` | none | `hello: {name}` | R |
| `diagnostics` | none, protocol 13 or later | `diagnostics._0` | R |
| `catalogue` | none | `catalogue._0` | R |
| `creation` | `_0: CreationAction` | `creation._0` | mixed |
| `previewAddress` | `_0: address` | `text._0` | R |
| `terminalStream` | `workspaceID`, `name` | `text._0` internal stream socket | M |
| `project` | `repoID`, `action: ProjectAction` | action dependent | mixed |
| `composer` | `sessionID` | `composer._0` | R |
| `setComposer` | `sessionID`, `controls` | `accepted`, or `created` when changing agent | M |
| `markRead` | `sessionID`, `seq` | `accepted` | M |
| `renameSession` | `sessionID`, `title` | `accepted` | M |
| `closeSession` | `sessionID` | `accepted` | M |
| `create` | `_0: WorkspaceRequest` | `created` or `creation._0.workspaceStarted` | M |
| `transcript` | `sessionID`, `afterSeq` | `transcript._0` | R |
| `changes` | `workspaceID`, `scope` | `changes._0` array | R |
| `patch` | `workspaceID`, `path`, `scope` | `patch._0` string | R |
| `reviewSnapshot` | `workspaceID`, `scope`, optional `knownRevision`, `wait` | `reviewSnapshot._0` | R |
| `reviewPatch` | `workspaceID`, `path`, `scope`, optional `knownRevision` | `reviewPatch._0` | R |
| `file` | `workspaceID`, `path` | `file._0` | R |
| `workspace` | `workspaceID`, `action: WorkspaceAction` | action dependent | mixed |
| `configure` | `sessionID`, `model`, `effort`, `permissionMode` | `accepted` | M |
| `send` | `sessionID`, `text` | `accepted` | M |
| `cancelQueued` | `sessionID`, `deliveryID` | `accepted` | M |
| `stop` | `sessionID` | `accepted` | M |
| `answer` | `sessionID`, `requestID`, `answer: Answer` | `accepted` | M |

### CreationAction

Wrap these inside `creation._0`. Unnamed arguments use `_0` again.

| Case | Arguments | CreationResult case | Kind |
| --- | --- | --- | --- |
| `projectContext` | none | `projectContext._0` | R |
| `inspectProject` | `_0: typedPath` | `inspection._0` | R |
| `startProject` | `typed`, `expected` inspection facts | `project._0` | M |
| `githubRepositories` | `query`, `page` | `repositories._0` array | R |
| `importGitHub` | `_0: owner/repository` | `project._0` | M |
| `workspaceContext` | `_0: repoID` | `workspaceContext._0` | R |
| `checkouts` | `_0: repoID` | `checkouts._0` | R |
| `resolveReference` | `repoID`, `reference` | `reference._0` | R |

`workspaceContext` supplies branches, branch prefix, setup-script availability, files and composer
choices. `WorkspaceRequest` requires `repositoryPath`, `name`, `agent`, `model`, `effort` and
`permissionMode`. Optional fields are `prompt`, `baseBranch`, `checkout`, `controls`, `mode`
(`chat`, `terminal`, `browser`), `runSetupScript`, and `attachments` (each has `sourcePath`, `name`,
Base64 `data`). Copy server-provided controls and checkout values rather than inventing them.
The `startProject.expected` facts prevent applying a stale inspection to a changed folder.

### ProjectAction

Wrap these inside `project.action` alongside the repository ID.

| Case | Arguments | Result | Kind |
| --- | --- | --- | --- |
| `rename` | `_0: name` | `accepted` | M |
| `setHidden` | `_0: bool` | `accepted` | M |
| `setAccent` | `_0: six-digit hex` | `accepted` | M |
| `settings` | none | `projectSettings._0` | R |
| `saveSettings` | `edits`, `expected` current RepoSettings | `projectSettings._0` | M |
| `filesToCopy` | `patterns` array | `filesToCopy._0` | R |

### WorkspaceAction

Wrap these inside `workspace.action` alongside the workspace ID.

| Case | Arguments | Result | Kind |
| --- | --- | --- | --- |
| `rename` | `_0: name` | `accepted` | M |
| `setPinned`, `setUnread` | `_0: bool` | `accepted` | M |
| `setColour` | optional `_0: hex`, null/omitted clears | `accepted` | M |
| `runSetup` | none | `accepted` | M |
| `archivePreview` | none | `archivePreview._0` | R |
| `archive` | `confirmation` UUID from archive preview | `accepted` | M |
| `restore` | none | `accepted` | M |
| `files` | none | `files._0` relative-path array | R |
| `pullRequest` | none | `text._0` URL or empty string | R |
| `runScripts` | none | `runScripts._0` array | R |
| `browserAddress` | none | `text._0` resolved server-side preview URL | R |
| `runScript` | configured script `id` | `terminalPane._0` | M |
| `download` | relative `path` | `download._0: {path,data}` | R |
| `writeFile` | `path`, `text`, last `revision` | `file._0` | M |
| `uploadFile` | `name`, Base64 `data` | `text._0` stored relative path | M |
| `commit` | `message` | `text._0` | M |
| `push` | none | `text._0` | M |
| `createPullRequest` | `title`, `body`, `draft` | `text._0` URL | M |
| `terminal` | `name` | `terminal._0: {executable,socket,session}` | M |
| `closeTerminal` | `name` | `accepted` | M |
| `notes` | none | `text._0` | R |
| `saveNotes` | `_0: text` | `accepted` | M |
| `newSession` | `agent`, `model`, `effort`, `permissionMode` | `created` | M |

Archiving requires reading its preview and submitting the returned opaque confirmation UUID.
Show the reported hazards before asking the user to confirm. The server retains that confirmation
and rechecks the workspace; a client cannot supply its own safety report. `commit` stages all
changes before committing. `createPullRequest` also pushes the branch. These are user actions,
not background refresh operations.

### Answer and composer state

`Answer` is one tagged case: `allowOnce`, `allowSession`, `allowProject`, `deny` (empty objects),
`denyWithReason: {message,endsTurn}`, `approvePlan: {mode}`, or `question: {input}`. `input` is a
JSON value matching that agent's pending question. Use the agent request ID, not the transport
request UUID. Permission modes and supported controls differ by agent. Read `composer` or the
creation context and submit compatible server-advertised values through `setComposer`.

## Agent requests to a client UI

`uiBridge` lets a running server agent call the existing Bloom MCP tools against one connected
client. Server-owned operations still run on the server. Pane, tab and browser actions are
validated by the same workspace/role-scoped tool handlers and delivered to the selected UI.

An attachment is explicit and belongs to one workspace and client:

- `attach {workspaceID, clientID, actions}` advertises implemented action names and returns
  `attached._0` containing a server-minted lease `{id, token, workspaceID, expiresAtMilliseconds}`.
  Keep the original request UUID when retrying an uncertain attach. Another client cannot replace
  an existing lease; detach it or allow it to expire first.
- `poll {leaseID, token, wait}` returns `requests._0` containing a renewed lease and request list.
  Each request has `{id, workspaceID, action: {name, arguments}, expiresAtMilliseconds}`.
- `claim {leaseID, token, requestID}` returns `claimed._0` as a Boolean. Claim immediately before
  executing each fetched action, and check the claim while an asynchronous action is running.
  False means the request was cancelled or expired; do not execute it. Repeating a claim is
  idempotent. A fetched batch alone is not permission to execute a later-cancelled action.
- `respond {leaseID, token, requestID, result}` acknowledges one claimed request. A result has `text`,
  `isError`, optional JSON `value` and optional Base64 `png`. Retry a lost result acknowledgement
  with the same result; never perform the UI action twice.
- `detach {leaseID, token}` gives up UI ownership. Stop polling when the workspace closes or the
  app becomes inactive. Unavailable clients, unsupported actions and expired requests fail
  explicitly rather than opening a window on another device.

Lease and UI-request deadlines use **Unix milliseconds**, explicitly named in these fields.
Existing domain-record dates still use the 2001 epoch described above. Lease tokens belong in
connection memory, not logs or screenshots. UI replies must match the current workspace and lease.
Browser tools retain their existing narrow scripts and approval rules; UI routing does not grant
arbitrary JavaScript execution or broader access to another workspace.

## Delivery, retries and errors

Create a new UUID for a new command. For a mutation, persist the **entire negotiated request**
before sending it, including its UUID, version and operation. If the connection fails before the
reply arrives, the server may already be executing it. Refresh state and, where appropriate,
retry that exact saved request. Do not generate a second UUID for an uncertain outcome.

The server stores mutation records durably before executing them. Concurrent identical retries
share the work; later retries return the recorded reply. Reusing an ID with a different operation
is refused. A server crash after recording the request but before recording the outcome returns
an unknown-outcome failure on retry. It does not rerun the operation. Inspect the workspace before
choosing a new action. This protects against duplication; it is not a transaction across Git,
filesystems, external APIs and process execution.

`accepted` means the command was accepted/applied at the runtime boundary. A sent prompt can be
queued, and an agent can continue after the client closes. Poll the transcript/catalogue for the
resulting state. Stopping an agent is a separate `stop` command. A cancelled network request is
not a `stop` command.

An application failure is `{"failure":{"_0":"human-readable explanation"}}`. There are no
stable numeric error codes yet. Apart from the explicit version-negotiation string, do not branch
on translated or changing failure text. Preserve the explanation for the user and refresh state
before offering a retry.

HTTPS transport errors are separate: 400 invalid/version-mismatched request, 401/403 missing or
refused access, 404 route mismatch, 405 wrong method, 413 oversized body, 415 wrong content type,
and 502 runtime unavailable/invalid response. Gateway error bodies can be plain text, not Bloom
JSON. On SSH, malformed/oversized input can close the channel without an application reply.

## Limits and terminal/preview bindings

| Boundary | Current limit |
| --- | --- |
| RPC request/reply | 16 MiB; also applies to encoded Base64 overhead |
| Native RPC resource timeout and gateway RPC timeout | 660 seconds |
| Persisted transcript page | 500 messages |
| In-progress assistant text | Bounded on server; when above 262,144 UTF-8 bytes it retains the last 65,536 characters |
| Review long poll | 15 seconds |
| Read/edit text file | 2,097,152 bytes |
| Binary upload/download | 8,388,608 bytes before Base64 |
| Prompt and notes | 1,048,576 UTF-8 bytes |
| Terminal name | 1 to 64 ASCII letters, digits, hyphens or underscores |

For HTTPS terminals, open authenticated
`wss://<api-origin>/v1/terminal?workspace_id=<id>&name=<name>`. This can create a tmux terminal and
is not read-only. Server output and client input are binary WebSocket frames. Resize is a text
frame `{"kind":"resize","columns":120,"rows":40}`, with columns 2...500 and rows 2...300.
The gateway's inbound frame limit is 16,384 bytes; server output chunks are at most 65,536 bytes.
`terminalStream` returns a short-lived internal Unix socket for a transport adapter; it is not a
TCP address a remote client can open directly. Terminal native UI is separate from RPC framing.

`previewAddress` resolves a workspace-local app address through the configured gateway or private
preview configuration. It does not by itself create a public route. Over SSH, the native app can
instead use a host-key-pinned `direct-tcpip` channel to the server's `127.0.0.1:<app-port>`, bound
to an ephemeral client loopback port. That byte tunnel is independent of RPC. Bind locally only;
do not disable host verification or expose the development port publicly.

A preview webpage has a different authority from agent control. Never inject the API bearer token
into WebKit/browser cookies, JavaScript, query strings or application headers. HTTPS preview login
uses a separately scoped identity and origin. Local SSH previews use an app-owned lease and refuse
unrelated local HTTP origins. Multi-origin Vite/HMR applications need each required origin to be
handled explicitly; an app port does not automatically forward every service port.

## Domain records and schema coverage

The schema strictly describes case names, envelope shapes, required operation fields and the
portable file/review/message records, queued prompts and archive safety reports. `DomainRecord` intentionally preserves complex application
records without claiming complete generated client models. It accepts an object and is not a
substitute for semantic validation. The server remains authoritative. The following sources define
those records, including fields not yet projected by the mobile client:

| Payload | Exact definition |
| --- | --- |
| Repository, workspace, session, message | [`Models.swift`](../Sources/BloomCore/Model/Models.swift) |
| Creation context/inspection/results/attachments | [`ServerCreation.swift`](../Sources/BloomCore/Server/ServerCreation.swift) |
| Composer controls and choices | [`ServerComposerState.swift`](../Sources/BloomCore/Server/ServerComposerState.swift), [`ComposerControls.swift`](../Packages/BloomClient/Sources/BloomClient/Composer/ComposerControls.swift) |
| Project settings | [`ServerProjectSettings.swift`](../Sources/BloomCore/Server/ServerProjectSettings.swift) |
| Archive confirmation and safety | [`ServerSidebar.swift`](../Sources/BloomCore/Server/ServerSidebar.swift), [`WorkspaceSafetyReport.swift`](../Packages/BloomClient/Sources/BloomClient/WorkspaceSafetyReport.swift), [`ArchiveHazards.swift`](../Packages/BloomClient/Sources/BloomClient/ArchiveHazards.swift) |
| File and revision snapshots | [`ServerProtocol.swift`](../Sources/BloomCore/Server/ServerProtocol.swift), [`ServerReviewCache.swift`](../Sources/BloomCore/Server/ServerReviewCache.swift) |
| Read-only cross-platform record projections | [`RemoteCatalogue.swift`](../Packages/BloomClient/Sources/BloomClient/RemoteCatalogue.swift) |

The shared client preserves archived workspaces, queued prompts and permission decisions from the
server. Older responses that omit those additive fields decode to empty collections. Transcript
snapshots replace queue and decision state even when no new messages arrive. Queued cancellation,
archive preview, confirmed archive and restoration have typed shared service methods. Keep the
same command ID when retrying an uncertain mutation; archive also returns the unchanged confirmation
ID issued by the server. Shared `WorkspaceSafetyReport` and `ArchiveHazards` retain the desktop's
loss descriptions and safety decisions. Incomplete risk reports fail decoding rather than implying
that archiving is safe.

Production vectors cover common conversation mutations, queue cancellation, archive confirmation,
restoration, terminal setup, catalogue and composer replies. They do not yet cover every operation
or result variant. The generator checks every enum case name and associated argument name, but
`DomainRecord` payloads still need field-level schemas and additional vectors before generated
clients can claim complete domain coverage.

A minimal client needs only catalogue selection, transcript merging, composer choices and the
review/file records above. Preserve opaque controls and expected-state objects when sending them
back. A client implementing project-setting editing or advanced checkout choices must implement
the referenced record contract too. The schema is a useful validation surface, not an assertion
that those advanced domain models already have a language-neutral generated SDK.

## Try the example and verify the contract

After trusting your SSH server key through your normal administration process:

```sh
python3 Protocol/examples/bloom_client.py --ssh-host server.example.com --ssh-user bloom catalogue
python3 Protocol/examples/bloom_client.py --ssh-host server.example.com transcript --session SESSION_ID --after 0 --decode-payloads
python3 Protocol/examples/bloom_client.py --ssh-host server.example.com reviewSnapshot --workspace WORKSPACE_ID --scope branch
python3 Protocol/examples/bloom_client.py --ssh-host server.example.com reviewPatch --workspace WORKSPACE_ID --path README.md
python3 Protocol/examples/bloom_client.py --ssh-host server.example.com file --workspace WORKSPACE_ID --path README.md
```

For HTTPS, obtain an access token through the configured OAuth flow and supply it as
`BLOOM_ACCESS_TOKEN` using your secret manager, then run
`python3 Protocol/examples/bloom_client.py --https https://bloom.example.com catalogue`.
The example does not implement OAuth login or automatic retries. It never disables TLS or SSH
host checks. `Client.command(...)` returns an envelope; a caller can explicitly retry the unchanged
value with `Client.perform(command)` after a transport failure. It deliberately rejects mutations.

Run `python3 Protocol/generate-schema.py --check` to check the version and Swift case inventories.
The schema uses JSON Schema draft 2020-12. For its executable contract check, install `jsonschema`
in a disposable Python environment, generate the vectors from the real Core Codable types, and
validate them:

```sh
BLOOM_PROTOCOL_VECTORS=/tmp/bloom-wire-vectors.json BLOOM_TEST_SWIFT_ARGS='-j 2' Tools/test-core.sh ServerProtocolVectorTests
python3 Protocol/verify.py /tmp/bloom-wire-vectors.json
python3 -m unittest discover -s Protocol/examples -p 'test_*.py'
```

The checked-in [vectors](../Protocol/vectors-v14.json) contain only synthetic identifiers and data.
The verifier also compares freshly encoded values with these examples so encoding drift requires
reviewing and updating the published samples. The vector test includes unnamed/nested enums, optional omission, opaque IDs, Base64 bytes and the
2001 date epoch. The verifier checks every vector against the schema and checks that the schema
still matches the source inventory. Add vectors and update the schema when changing this contract;
changing a wire case without doing so should fail the check. These checks do not replace a live
SSH/HTTPS deployment test or justify silently accepting another protocol version.

Agent authentication metadata is optional on composer records and diagnostics, as an
`authentication` array of `{ "agent": "codex", "state": "signInRequired" }` records. States are
`ready` (a saved CLI login, not an online validation), `signInRequired`, `unavailable`, and
`unknown`. Absent metadata means the older server cannot perform this preflight. Unknown does
not block custom providers. Container checks run in the configured workspace execution wrapper
after setup; an unconfigured checkout cannot reliably inherit the main checkout's login state.

A failed authentication preflight leaves a queued delivery unsent and durably pauses its queue.
There is no automatic authentication retry. After sign-in, send the existing head's text with
the optional `retryDeliveryID` field on `send`. Only clients that have received authentication
metadata may use this field, because older servers ignore it. The server atomically requires
the same pending head ID and text, an authentication pause, and no delivery receipt. It resumes
that existing delivery without inserting another. A removed, changed or already delivered
message is refused. Ordinary `send` calls without this field retain distinct identical prompts.
