# Concurrency diagnostics

Use the actual compiler diagnostic and target settings. Do not apply fixes in a universal order.

| Diagnostic | What to establish before editing |
| --- | --- |
| Sending a value risks data races | Is it shared concurrently or transferred once? Use checked `Sendable` for safe sharing, `sending` for a valid transfer, or keep use within the same isolation domain. |
| Static property is not concurrency-safe | Is it immutable and Sendable, actor-owned, or protected by a lock? Choose the real owner rather than putting every global on MainActor. |
| Capture of a non-Sendable value | Does the closure actually cross isolation, and must it retain the whole object? Capture transferable values or isolate the work deliberately. |
| Conformance crosses actor isolation | Does the protocol need nonisolated callers or an actor-isolated conformance? Isolated conformances restrict use; they do not make the type safe everywhere. |
| Expression is async without await | Identify the async call or actor hop. Make the caller async where appropriate, or use an owned task at a synchronous entry point. |

`nonisolated(nonsending)` can preserve caller isolation for a suitable async helper; it is not a
universal escape from Sendable requirements. See [Swift 6.2 settings](new-features.md).
`@preconcurrency`, `@unchecked Sendable` and `nonisolated(unsafe)` need an existing safety guarantee,
not just a desire to silence the compiler. See [bridging](bridging.md).
