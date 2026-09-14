# Testing concurrency

Use the shared [Swift Testing async guide](../../swift-testing-pro/references/async-tests.md) for
serialisation, confirmations, readiness signals and cancellation tests. Use the
[testing skill](../../swift-testing-pro/SKILL.md) for Bloom's test commands and isolation rules.

- Exercise real actor APIs through `await`; do not add unsafe accessors for tests.
- Force the relevant interleaving with explicit signals or injected dependencies. Sleeps and
  `Task.yield()` cannot guarantee that another task reached a suspension point.
- Verify cancellation behaviour in production code and release all test-owned tasks and signals
  when assertions fail. Assert cleanup as well as termination.
- For suspected data races, use the existing nightly Thread Sanitizer job or a targeted run with
  `BLOOM_TEST_SWIFT_ARGS='--sanitize=thread'`. TSan cannot detect every logical actor-reentrancy bug.
