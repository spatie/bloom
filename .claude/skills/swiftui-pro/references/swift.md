# Swift and Foundation in UI code

Follow neighbouring code and `CLAUDE.md`. Prefer API changes that improve correctness or clarity
without introducing unrelated churn.

- Use Foundation URL and format-style APIs where they express the required semantics. Keep
  locale-independent formatting for protocols, file names and external data contracts.
- `localizedStandardContains` often fits user-facing search. Case-sensitive or literal matching
  may be required for code, paths or protocol data; choose the intended search semantics.
- Prefer `count(where:)` over allocating a filtered collection solely to count it.
- Avoid force unwraps and swallowed errors on user-input paths. Show errors through Bloom's
  existing UI error handling rather than logging a failed user action invisibly.
- Add `Comparable` only when a type has a meaningful natural ordering. Reusing a sort closure
  alone is not a reason to declare a total order for the entire type.
- Use `CGFloat` or `Double` according to the API boundary. Do not force conversions for style.
- Use `PersonNameComponents` when formatting structured names, but preserve user-supplied display
  names without trying to split them into guessed components.

For async or actor-isolated code, use the shared
[concurrency skill](../../swift-concurrency-pro/SKILL.md). A `Task` created on MainActor does not
move synchronous CPU work to the background.
