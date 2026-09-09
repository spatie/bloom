# Callback and concurrency boundaries

Use an existing async overload when it preserves the required API behaviour. Otherwise bridge a
single completion with `withCheckedContinuation` or `withCheckedThrowingContinuation`.
Every execution path must resume exactly once, including cancellation, errors and missing callbacks.
Concurrent completion and cancellation paths need synchronised access to continuation state;
a plain shared Boolean is not enough.

Checked continuations detect misuse but do not implement timeouts or cancel the underlying work.
Unsafe continuations are not a repair for double resume. Consider them only with profiling evidence
and a proven lifecycle.

Repeated delegate events fit `AsyncStream`; see [streams](async-streams.md) for termination and
buffering. If callbacks require a particular executor, encode that guarantee in the interface or
hop to the actor. Use `MainActor.assumeIsolated` only for an executor guarantee already established
by the calling API.

`@unchecked Sendable` is a promise of thread safety, not a synchronisation mechanism. Audit every
mutable field and access path. Prefer checked Sendable values, actors or a lock-backed design.
Immutable reference types and manually synchronised types can be legitimate uses when their
safety is established. Check whether region-based transfer or `sending` expresses the intended
ownership without an unchecked conformance.
