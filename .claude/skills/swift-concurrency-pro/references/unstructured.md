# Unstructured tasks

`Task {}` inherits lexical actor isolation, task-local values and priority from its creation
context. It does not become a structured child and does not inherit cancellation propagation.
`Task.detached` does not inherit actor isolation or task-local values; choose its priority
explicitly if needed.

Use unstructured tasks for a synchronous-to-async entry point or work with an independent lifetime.
Store the handle when the owner needs cancellation or a result, or handle errors within the task.
A discarded throwing task handle can hide failure. Cancelling a task does not interrupt its body.

For work owned by a view's appearance, prefer `.task` or `.task(id:)` over starting a loose task
from `onAppear`. For an app service that outlives the view, keep ownership in the model or service.
Avoid strong self-capture in a long-running task when it prevents the owner reaching teardown.

For CPU work, an explicit `@concurrent` async helper usually expresses the boundary more clearly
than a detached task. Do not replace detached tasks without preserving their lifetime and error
handling. See [Swift 6.2 settings](new-features.md) before assuming where an async helper executes.
