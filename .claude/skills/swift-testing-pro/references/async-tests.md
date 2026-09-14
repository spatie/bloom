# Async tests

Use `async throws` tests and await the operation or task handle that produces the result.
A fixed sleep or `Task.yield()` does not prove another task has started or finished.

## Serialisation

In Swift 6.2, `.serialized` on a parameterised test runs that test's cases sequentially. On a
non-parameterised test it has no effect. On a **suite**, it serialises its contained tests and
sub-suites, including ordinary tests. It does not exclude unrelated suites from running alongside
it and does not establish a test order. Prefer isolated resources over global shared fixtures.

Source: [Swift Testing 6.2 ParallelizationTrait](https://github.com/swiftlang/swift-testing/blob/swift-6.2-RELEASE/Sources/Testing/Traits/ParallelizationTrait.swift).

## Confirming completion

`confirmation` counts events during its body; it does not wait for future callbacks. Ensure
that the work completes before the body returns, and call the confirmation from the actual event:

```swift
await confirmation(expectedCount: 1) { confirmed in
    await worker.run {
        confirmed()
    }
}
```

This assumes `worker.run` awaits the callback. If it returns a task, await that task's value
inside the confirmation body instead. For callback-only APIs, bridge completion with a checked
continuation and ensure success, error and cancellation paths cannot hang or resume twice.
Use a cancellation-aware timeout if the callback can be lost; a test time limit cannot forcibly
stop arbitrary non-cooperative code.

Register event listeners before triggering an event. When subscription itself is asynchronous,
use an explicit readiness signal. Do not rely on yielding to install a notification observer.
`confirmation(expectedCount: 0)` only rules out events during the observed scope.

## Isolation and cancellation

Annotate tests or suites with `@MainActor` only when their subject requires it. Actor isolation
serialises synchronous segments, not entire tests across suspension points. An `isolation`
argument on a testing helper does not replace the closure's required actor annotations.

For cancellation tests, use a readiness signal from the subject or an injected dependency,
cancel while work is active, and await completion. Assert its documented cancellation result
and cleanup; some APIs throw `CancellationError`, others use their own errors or finish normally.
Always release test gates and cancel owned tasks on failure as well as success.

Swift 6.2 test limits use `.timeLimit(.minutes(1))`, not `.seconds(...)`. A suite limit applies
per test; when multiple limits apply, the shortest wins. Do not use wall-clock delays as assertions.
