# Core rules

- Use `import Testing`, `@Test`, `#expect` for assertions and `try #require` for prerequisites or
  optional unwrapping. A thrown requirement failure stops the current throwing scope.
- Prefer a struct suite; classes are valid when reference semantics or `deinit` are needed.
  `@Suite` is only needed to add traits or a display name. Instance tests require an initialiser
  callable without arguments; it may be async or throwing.
- Use `init` or local setup and `defer` for cleanup. Each instance test gets its own suite instance,
  but static values, process environment and external resources are still shared.
- Tests and parameterised cases run in parallel by default, with no ordering guarantee.
  See [async tests](async-tests.md) before using `.serialized`.
- Parameterised tests accept one or two argument collections. Two collections produce a Cartesian
  product; use one collection of tuples or `zip` when values should be paired.
- `#expect(!condition)` is supported. Choose assertion spelling for readable diagnostics, not a
  blanket ban on Boolean negation. Lift mutating calls into a local before asserting.
- Use `withKnownIssue` only for a tracked, unresolved failure. It records an issue if the expected
  failure disappears, unless `isIntermittent: true` was deliberately selected.
- Add tags and descriptive messages where they aid filtering or diagnosis; no mandatory tag set.
- Keep availability annotations on individual tests when an API needs a newer platform.
  Check the installed testing library before adding version-dependent traits or suite annotations.
