# Architecture and contributor guide

Bloom separates its tested behaviour from its window. Read `CLAUDE.md` for the enforced rules and
`RELEASING.md` for distribution. Build an isolated dev copy; never test against the installed
production app or its database.

## Boundaries

- `BloomCore` owns persistence, processes, agent protocols, workspace operations and pure
  presentation decisions. It cannot import a UI framework.
- `Bloom` owns SwiftUI and AppKit integration. Main-actor observable models coordinate the window;
  views render state and forward intent rather than running shell commands.
- `bloom-bridge` relays MCP requests to the running app. The registry establishes caller authority;
  dispatch checks tool roles. Existing connections revalidate tokens for each request.
- `bloom-server` runs a standalone `ServerRuntime` with its own database and agent processes.
  The Mac server window connects through a private socket or SSH. Existing local execution stays
  in the app during this migration. See `SERVER.md` for the implemented slice and remaining work.

Files are grouped by subject, not into generic helpers or services. Extract a component when it
owns a coherent responsibility or removes repeated behaviour. Do not split a file merely to meet
a line count, or expose private mutable state just to make an extension possible.

## State and concurrency

Lifecycle rules belong in value types with explicit events and outcomes. Existing examples are
`SessionLifecycle`, `SetupState`, `SubagentState` and `DeliveryDrainState`.
Use a state machine when transitions have rules, cancellation or asynchronous hand-offs. A single
independent preference does not need a state machine simply because it is a boolean.

An actor serialises synchronous work, not an entire operation containing `await`. Recheck state
after suspension. The delivery drain has one owner and coalesces competing requests; SQLite
conditionally claims each pending delivery. Codex startup uses a cancellation generation so Stop
cannot be undone by a late connection or turn-start reply. Process factories make these races
testable without running a paid agent.

## Database structure

`Store` is the single actor owning the SQLite connection. Foreign keys connect projects,
workspaces, sessions, messages and deliveries. Ordered migrations and schema-repair checks are
covered by tests. Unsupported schema versions are refused before repair, and migration stamps
are throwing writes inside the migration transaction.

Keep SQLite here rather than introducing SwiftData alongside it: the app already relies on
explicit transactions, targeted updates, ordered transcript reads and migration compatibility.
A second persistence stack would duplicate ownership without solving a demonstrated problem.

`upsert` creates rows from newly constructed values. Existing rows use targeted updates inside
the actor, so a slow UI edit cannot overwrite newer runner or filesystem state. Operations that
must succeed together use one transaction: enqueue plus draft removal; fresh Ask conversation
plus preferences, draft and archival. Failure must preserve the recoverable state.

The SQLite wrapper binds and reads explicit byte lengths, preserving embedded NUL text and empty
blobs. Numeric conversion checks representability instead of trapping on corrupt values.

## Files and permissions

The setup-copy preview and copier share one resolver. Relative traversal is rejected, source
symlinks must stay inside the source root, and destination symlinks cannot redirect copied files.
Local HTML page access uses the same canonical containment primitive.

These checks constrain Bloom's own operations. They are not an operating-system sandbox against
a hostile local process changing files concurrently. An authorised setup script or agent can still
execute code with the access its selected mode grants. Review scope and permissions at boundaries;
do not describe a worktree as isolation equivalent to a virtual machine.

## Verification and review scope

Run focused core tests, build the app, and run both `make lint` and `make swiftlint`. The full suite
and warnings-as-errors app build run on the pull request. Fault-injection tests cover failed writes,
and fake-process tests cover protocol timing. Licence packaging is tested separately.

The September 2026 audit addressed concrete persistence, cancellation, duplicate-delivery,
file-containment and token-revocation findings. It also removed the duplicate copy walker and
centralised composer-setting persistence. This is not a claim that the entire application is free
of defects or that every interface has been interactively reviewed. Keep adding a regression test
for each reproducible defect, and profile before replacing a working native component.
