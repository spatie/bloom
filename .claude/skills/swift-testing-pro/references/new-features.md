# Version-dependent testing APIs

Bloom's minimum toolchain is Swift 6.2. Confirm signatures in the installed `Testing` module
before adopting newer features; examples from upstream main may require a later toolchain.

- Swift 6.2 raw identifiers allow backtick-delimited test names with spaces. Follow the existing
  naming style instead of renaming tests solely to adopt this syntax.
- Swift 6.1 adds range-based confirmations such as `expectedCount: 2...4` or `2...`.
  Ranges need a lower bound. The work still must finish inside the confirmation body.
- Custom `TestTrait` and `TestScoping` implementations can wrap test execution with task-local
  configuration. Keep values safe to share and match the installed `provideScope` signature;
  a `@TaskLocal` containing a mutable reference does not make its contents thread-safe.
- Swift 6.2 exit tests use `await #expect(processExitsWith: .failure) { ... }` to check termination
  in a child process. Verify platform support and avoid assumptions about parent-process state.
- Attachments can record useful logs or data. Prefer test-side `Attachment.record(value, named:)`
  with a supported value type; do not import `Testing` into production code. Check type and
  platform support before attaching images or custom values.
- `ConditionTrait.evaluate()` reports whether a condition permits the test to run. Do not invert
  its meaning for `.disabled(if:)`: a true disable condition means the test is not enabled.
- Modern `#expect(throws: ErrorType.self)` returns an optional matching error; `#require` is the
  throwing alternative when subsequent checks require a matching error. Do not assume the
  result of `#expect` is nonoptional.

Use these features when they simplify a real test, not as an upgrade checklist.
