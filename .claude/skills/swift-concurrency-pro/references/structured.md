# Structured tasks

Use `async let` for a fixed set of independent operations, and task groups for a dynamic set.
Children belong to the scope: the group waits for all of them before returning, even after
cancellation. Keep unstructured tasks when their intended lifetime is independent of this caller.

```swift
let results = try await withThrowingTaskGroup(of: Data.self) { group in
    for url in urls {
        group.addTask { try await fetch(url) }
    }
    var results: [Data] = []
    for try await result in group {
        results.append(result)
    }
    return results
}
```

Results arrive in completion order, not input order. Carry an index when input order matters.
For large inputs, seed a bounded number of children and add another when one completes.
`addTaskUnlessCancelled` can avoid adding work after cancellation.

An ordinary throwing task group's child error is surfaced when its result is consumed. It does
not automatically cancel siblings merely by being thrown in the child. If the error escapes the
group body, remaining children are cancelled and awaited. Catch errors inside children when
partial results are the intended outcome, and consume results to avoid silently losing failures.

Use `withDiscardingTaskGroup` or its throwing variant for children whose results are unused.
These still wait for children; they are not fire-and-forget. The throwing discarding variant
cancels siblings on a child failure. Cancellation remains cooperative in either variant.
