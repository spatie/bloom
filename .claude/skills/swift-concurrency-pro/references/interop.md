# Interop

Preserve working framework integration unless migration is needed for the task. GCD, locks,
delegates and Combine are not automatically bugs in Bloom's AppKit and subprocess code.

- Wrap a single completion in a checked continuation when an async entry point is needed.
  Do not add a wrapper when a suitable async overload exists.
- A repeated delegate stream can use `AsyncStream` with explicit producer cleanup.
- `@MainActor` expresses UI isolation. Replacing `DispatchQueue.main.async` with a direct call can
  change deferred ordering, so preserve any reason the work was queued for a later turn.
- A serial queue protecting state can become an actor if callers can use an async interface.
  For synchronous APIs, `Synchronization.Mutex` can keep protected state behind a Sendable boundary.
  Never hold a blocking lock across suspension or block a cooperative thread waiting for async work.
- `@concurrent` can explicitly move CPU-heavy async work off an actor. See
  [isolation settings](new-features.md) rather than assuming any `async` function runs in the background.
- Combine's `publisher.values` provides async iteration, but subscriber demand, buffering and
  event loss still need checking. `AsyncStream` is not a drop-in replacement for broadcast or
  replaying subjects. Keep Combine when those semantics or existing integration matter.
