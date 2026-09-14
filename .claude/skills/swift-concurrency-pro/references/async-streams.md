# Async streams

Use `AsyncStream.makeStream(of:)` when both the stream and continuation need to be stored.
The closure initialiser remains valid when it naturally owns registration and cleanup.

## Lifecycle

`AsyncStream.Continuation.finish()` ends production and is idempotent; later finishes or yields
have no effect. This differs from `CheckedContinuation`, which must be resumed exactly once.
Finish finite streams on completion and error paths, and connect consumer termination to producer
cleanup with `onTermination`. That handler is `@Sendable` and must respect isolation.

Breaking out of `for await` is not an explicit cancellation API for a retained stream. Ensure
producer shutdown through ownership or a stop method when early loop exit must release resources.
Do not rely on a retained continuation or iterator being destroyed immediately.

`AsyncStream` responds to cancellation while waiting for the next element. Arbitrary
`AsyncSequence` implementations define their own cancellation behaviour, and long work in a loop
body may need explicit cancellation checks. Code after a normally finished loop still runs.

## Buffering

The default buffer is unbounded. Select `.bufferingNewest(n)` or `.bufferingOldest(n)` when
lossy delivery is acceptable. Inspect `yield` results if dropped values matter. A bounded buffer
is a drop policy, not backpressure; `yield` does not suspend a fast producer. For lossless events,
such as agent output, use an appropriate flow-control strategy rather than silently dropping data.

Do not treat one stream as a broadcast channel for multiple consumers. Give subscribers their
own streams and lifecycle management when every subscriber must receive every event.
