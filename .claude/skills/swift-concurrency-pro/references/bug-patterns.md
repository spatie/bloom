# Recurring failure modes

Use these as review leads, not proof of a defect:

- Read state, await, then overwrite newer state with the old result. Revalidate state or use a
  generation check. See [actors](actors.md); a local result alone does not solve invalidation.
- Completion and cancellation both resume a continuation. Synchronise their shared state and
  let only one path take ownership of the resume. See [bridging](bridging.md).
- Discarded throwing task handles hide errors; long-running tasks outlive their intended owner.
  Preserve or deliberately end the lifetime and observe failures. See [unstructured tasks](unstructured.md).
- CPU-heavy work runs in a main-actor task. Inspect the called function's actual isolation before
  choosing an explicit offload. See [isolation settings](new-features.md).
- A producer outruns an unbounded stream. Choose buffering or flow control based on whether events
  may be dropped. See [streams](async-streams.md).
- Expected cancellation is retried or reported as an error. Check the API's actual cancellation
  result and preserve cleanup. See [cancellation](cancellation.md).
- `@unchecked Sendable` or `nonisolated(unsafe)` hides unprotected mutable state. Establish a real
  isolation or synchronisation boundary rather than adding another annotation.
