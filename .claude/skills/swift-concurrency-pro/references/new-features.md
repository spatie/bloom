# Swift 6.2 isolation settings

Check the target configuration and compiler invocation, not just the toolchain version.
Bloom's `Package.swift` sets Swift 6 language mode but currently enables neither of these options:

- `.defaultIsolation(MainActor.self)` makes eligible declarations main-actor isolated by default.
- `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` makes nonisolated async functions
  inherit caller isolation. This is a separate opt-in in Swift 6.2.

Without the second option, ordinary nonisolated async functions retain the earlier behaviour of
switching off an actor. `nonisolated(nonsending)` explicitly inherits caller isolation;
`@concurrent` explicitly switches an async function to the concurrent executor. Prefer the latter
for CPU-heavy work that must leave the main actor. Async I/O suspending does not itself block UI,
but synchronous processing around that I/O still can.

Source: [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).

## Other APIs

Use newer features only when the task needs them and the selected toolchain and SDK support them:

- Global-actor isolated conformances, such as `extension Model: @MainActor SomeProtocol {}`,
  restrict where that conformance can be used. They are not a fix for a protocol that must be
  callable from nonisolated code.
- `isolated deinit` permits teardown on a class's actor. A plain deinitialiser is not automatically
  actor-isolated merely because the class is; safe access to Sendable stored values may still work.
- `Task.immediate` can begin synchronously when already on the required executor. Use it only
  when that ordering matters and consider reentrancy before the task handle is assigned.
- Task naming and priority escalation are diagnostic or scheduling tools, not correctness fixes.
  Priority escalation is usually handled by the runtime when one task awaits another.
