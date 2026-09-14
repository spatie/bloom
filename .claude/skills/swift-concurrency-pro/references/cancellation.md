# Cancellation and teardown

Cancellation is cooperative. Cancelling a parent propagates to structured children, but not to
unstructured `Task` handles. `await` does not itself check cancellation. The awaited API may
check, throw its own cancellation error, finish a stream, or ignore cancellation.

- Use `try Task.checkCancellation()` or `Task.isCancelled` at safe points in long-running work.
  Finish mandatory cleanup and state transitions before exiting.
- Cancel superseded tasks if their results are no longer wanted. Also guard result delivery when
  stale work can finish despite cancellation.
- Cancel owned work during lifecycle teardown. A task strongly retaining its owner can prevent
  `deinit` from running, so a cancel-in-deinit alone may be insufficient.
- `withTaskCancellationHandler` connects cancellation to a callback API's cancel operation.
  Its synchronous `onCancel` may run concurrently with the operation; protect shared handles.
  Already-cancelled tasks still execute the operation body, after the cancellation handler.
  Account for cancellation arriving before a handle or continuation is registered.
- Do not put a no-op cancellation handler around `URLSession`'s async APIs: those already support
  cancellation. Check the actual error contract, including URL loading cancellation errors.
- Treat expected cancellation as a lifecycle outcome rather than showing a failure alert, unless
  the operation's contract requires reporting incomplete work.

Tests should synchronise on readiness and verify cleanup, not sleep and hope cancellation arrived.
See [testing](testing.md).
