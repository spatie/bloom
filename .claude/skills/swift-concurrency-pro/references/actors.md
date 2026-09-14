# Actor isolation and reentrancy

Actor-isolated synchronous code runs without another task interleaving on that actor. A suspension
at `await` lets other work change the state. Revalidate assumptions before committing a result.

```swift
actor Cache {
    private var values: [String: Data] = [:]

    func value(for key: String) async throws -> Data {
        if let cached = values[key] { return cached }
        let downloaded = try await download(key)
        if let cached = values[key] { return cached }
        values[key] = downloaded
        return downloaded
    }
}
```

This preserves a result another caller stored while the download suspended. It still permits
concurrent duplicate downloads. If deduplication matters, store an in-flight task per key before
awaiting it. Define who owns cancellation and how failed tasks are removed. If invalidation can
happen while work is in flight, use a generation or identity check so an old result cannot revive
invalidated state or clear a newer task.

Do not claim a cache can be cleared *between* an actor-isolated assignment and a following return
when there is no suspension between them. In Bloom, use `Store.update` for existing rows as
specified in `CLAUDE.md`; writing a stale whole-row value is a separate logical race.

## Boundaries

- Isolate UI state to `MainActor`; use another actor when it owns an independent async state
  boundary. A synchronous API may be better served by a lock.
- Check inferred isolation on subclasses, protocol conformances and extensions. A conformance
  declared in an extension does not necessarily isolate the entire type. Swift 6 removes the old
  outward actor inference from property wrappers such as `@StateObject`.
- `isolated` parameters let a function work within an actor's isolation. Cross-boundary values
  must be safe to share or transfer, considering `Sendable`, `sending` and region-based isolation.
- Closure isolation depends on its type and context; passing a closure to a nonisolated function
  does not by itself prove the closure runs off the actor.
- `assertIsolated()` is a debug assertion, not a hop. `assumeIsolated()` is a checked assertion of
  an existing executor guarantee, not a way to make an unsafe callback safe.

For module defaults and isolated conformances, see [Swift 6.2 settings](new-features.md).
