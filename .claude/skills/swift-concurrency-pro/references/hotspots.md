# Concurrency review search targets

Search the changed code first. A match identifies something to inspect, not an automatic finding.

| Pattern | Inspect |
| --- | --- |
| `Task {`, `Task.detached`, tasks in loops | Owner, cancellation, observed errors, intended isolation and lifetime. |
| `await` between state reads and writes | Reentrancy, stale results, cache invalidation and whole-row writes. |
| Continuations | Exactly one resume across completion, error and cancellation races. |
| `AsyncStream` | Bounded memory, permitted event loss, producer cleanup and early consumer exit. |
| `@unchecked Sendable`, `nonisolated(unsafe)` | The actual lock, immutability or isolation guarantee for every access. |
| `DispatchQueue`, locks, semaphores | Needed framework ordering versus blocking a cooperative executor. |
| `MainActor.run`, `assumeIsolated` | A necessary hop versus an assertion requiring an existing executor guarantee. |

Follow the relevant reference from [the skill index](../SKILL.md); do not load every guide for a
single match.
