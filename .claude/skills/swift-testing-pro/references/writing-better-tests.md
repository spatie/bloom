# Test design

Test the behaviour changed by the task, including relevant failure and boundary cases. Regression
checks should fail for the original bug. Avoid exhaustive boilerplate for every function and tests
that merely repeat implementation details.

## Isolation and dependencies

Follow the existing `Tests/BloomCoreTests` layout and fixture helpers. The test target cannot
import SwiftUI or the app; test decisions through BloomCore. UI rendering or automation requires
a separate approach when it is actually in scope.

Inject the dependencies needed to control time, randomness, network replies and persistence.
Use the project's existing seams; a closure or value may be simpler than another protocol.
Do not change a production API just to make a generic mock example fit.

Use a unique temporary directory or `UserDefaults` suite per test and clean it up with `defer`.
Never test against the owner's Bloom database or preferences. Unit tests should use controlled
network responses; real CLI/network integration tests stay explicitly opt-in.

## Assertions

Use `try #require(optional)` instead of a force unwrap when later assertions need the value.
Check the behaviour's specific error when it matters:

```swift
#expect(throws: GameError.notInstalled) {
    try game.play()
}
```

Use `do`/`catch` and `Issue.record` when error handling needs more control. If an error is allowed
to escape, an `async throws` test already fails on an unexpected throw.

Use a tolerance chosen for the domain for floating-point results. A simple absolute tolerance
can use `#expect(abs(actual - expected) <= tolerance)`; account for relative error, infinities and
NaN when those are part of the contract. Adding a numerical library is not required for this.

Verification helpers should forward the caller's source location:

```swift
func expectCount(_ actual: Int, _ expected: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
```

Use parameterised tests to remove repeated setup where it keeps failures clear. Add `.bug(...)`
for an existing issue when useful, and keep test-only diagnostic conformances out of production.
