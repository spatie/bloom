# Requested XCTest migrations

Only migrate tests included in the requested work. Swift Testing and XCTest can coexist in a
project; keep XCTest for UI automation.

| XCTest | Swift Testing |
| --- | --- |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertLessThan(a, b)` | `#expect(a < b)` |
| `XCTAssertThrowsError` | `#expect(throws:)` with the expected error |
| `XCTUnwrap(value)` | `try #require(value)` |
| `XCTFail(message)` | `Issue.record(message)` |
| `XCTAssertIdentical(a, b)` | `#expect(a === b)` |

Replace `XCTestCase` inheritance with an appropriate suite and mark tests with `@Test`. Preserve
coverage, setup and cleanup semantics; use `init`, `defer`, or test scopes where appropriate.
Check shared resources because migrated tests may now run concurrently. Await actual completion
rather than translating XCTest expectations directly into `confirmation`.

For floating-point tolerance, see [test design](writing-better-tests.md). No new dependency is
required merely to replace `XCTAssertEqual` with an accuracy argument.
