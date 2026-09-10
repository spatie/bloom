# Code quality review, September 2026

This review covered module boundaries, duplicated client behaviour, remote connection recovery,
server task lifetimes, installer cancellation, gateway request handling and build isolation. It
was a targeted review of those paths, not a claim that every line or security boundary has been
exhaustively audited.

## Structure to preserve

BloomCore owns execution and the private SQLite Store. BloomClient owns portable protocol,
parsing and client state. BloomUI shares rendering. AppKit and UIKit own their respective native
interaction adapters, while BloomAuthentication and BloomSSH keep transport-specific integration
separate. This is a useful division for adding features across Mac, iPhone and iPad.

Several similarly named Core and package files are compatibility type aliases, not duplicate
parsers. Transcript, markdown, syntax, diff and composer decisions already have shared owners.
Moving native controllers into a common view hierarchy would not remove the most consequential
duplication. Shared state transitions and persistence are the better boundary.

Store is intentionally large around its private database connection and atomic update rules.
Splitting it merely to reduce line counts would expose its internals. Likewise, use small lifecycle
types where states or races demand them, rather than an action class for every method.

## Changes made

- Both clients use the shared connection recovery policy and durable pending-command identity.
  Transient failures retain cached content and drafts, with automatic backoff and manual retry.
  Authentication and trust failures require user action. Uncertain prompts are retried explicitly
  with their original ID; reconnect does not silently submit them again.
- Mac and iOS notes now share draft persistence and one serial save coordinator. A late response
  cannot erase newer text, cancelled loads cannot replace edits, and local persistence failures
  prevent a network write. Platform views supply transport and native editing only.
- Remote editor refreshes use in-memory snapshots carrying server revisions. They no longer write
  a temporary plaintext file every few seconds. Local file conflict checks remain separate.
- iOS approval retries resolve the current connection while retaining the original decision ID
  and server origin. WebKit observation keeps browser history, title and navigation controls current
  during single-page navigation.
- Server queue cancellation closes admission to replacement drains while deletion is pending.
  Concurrent cancellations share that protection, and cancellation checks the actual delete result.
- Terminal shutdown rejects new streams, waits for starts already in progress and reaps owned
  client processes with bounded termination. Closing a client does not kill its remote shell.
- Gateway terminal requests validate the WebSocket upgrade before allocating a runtime stream.
  Gateway shutdown awaits the active HTTP request drain before allowing its entry point to exit.
- Installer interruption unwinds account-worker ownership on TERM, HUP and INT. Repeated signals
  cannot interrupt the child-reaping cleanup. Failures remain structured and suitable for the UI.
- Installed build scripts share lifecycle locks and staged, verified publication. A failed build
  retains the installed app. No-launch installation refuses a running destination. iOS builds use
  persistent per-checkout caches with locks covering generation and compilation.
- Core tests compile immutable snapshots instead of symlinks into actively edited sources. SwiftPM
  snapshot planning tracks local package file membership, so adding a source file cannot leave a
  stale build plan. CI runs the script regressions and watches the relocated protocol definitions.

## Evidence and limits

The two server races were reproduced before their fixes. Afterwards, 58 focused Core tests passed
with warnings as errors (33 runtime, 9 terminal stream and 16 editor tests). The final queue
refinement passed the 33 runtime tests again. Shared note tests passed 7 cases; approval recovery
passed 2. Connection recovery and durable draft regressions passed in the preceding change.

The script runner ran 138 Python tests successfully, with 5 Linux-root-only cases skipped on macOS, plus
54 release fixture checks. Both repository linters and actionlint passed. Actionlint was run
without its optional ShellCheck and Pyflakes integrations. The Mac app build and iPhone/iPad Simulator build passed;
Xcode still emits its existing unused AppIntents metadata extraction warning. Gateway race tests
and `go vet ./...` passed, including regressions that failed before the two lifecycle fixes.

Fault-injection tests establish the tested recovery behaviour. This batch did not include a live
train-style network interruption or a new iOS device deployment. Linux execution and a fresh
runtime archive remain pending because the local container engine is stopped. Reusing the previous
protocol-compatible installer archive does not include the new server fixes. The Server workflow
builds and exercises Linux, including packaged runtime checks without Swift installed.

## Follow-up priorities

1. Reconnect the MCP UI attachment lease together with its execution/result identity cache. Merely
   reusing a client ID would not establish safe replay. An old lease can temporarily prevent a new
   attachment until expiry.
2. Bound terminal output for slow consumers through backpressure or an explicit disconnect policy.
   Dropping arbitrary bytes would corrupt terminal state; the underlying subprocess line stream
   currently uses an unbounded buffer.
3. Compact retained command-journal payloads with a documented idempotency retention policy.
   Full file-upload requests should not grow the database indefinitely.
4. Add revision-bearing note reads and conditional writes for cross-device conflicts. Current
   notes remain last-write-wins between devices; serial saves only order writes within one client.

These follow-ups need explicit semantics and regression tests. They should not be hidden inside a
cosmetic refactor or described as already solved by the changes above.
