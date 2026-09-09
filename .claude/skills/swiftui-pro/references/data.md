# State and bindings

Use a single clear owner for each value. `@State` can own local state or an `@Observable` model;
`@Binding` passes writable access, `@Bindable` exposes bindings to observable properties, and
`@Environment` supplies shared dependencies. Do not copy shared state merely to pass it down.

UI-facing mutable models generally belong on `MainActor`. `@Observable` itself does not add
synchronisation or require every observable type to be main-actor isolated. Check the model's
actual consumers and target settings before adding annotations.

Keep owned `@State` private. Use it for persistent view identity, not as an unsynchronised cache
of derived data. If a derived cache is needed, make invalidation explicit.

Prefer projected bindings where possible. `Binding(get:set:)` is valid for adapters, validation,
optional values and writes that need a model action. Replacing it with `onChange` can change
write timing or omit repeated equal-value writes; preserve those semantics.

For numeric input, consider a value-and-format `TextField` and define invalid-input behaviour.
Do not apply iOS keyboard modifiers to macOS. A formatted field is not automatically the right
choice when partially entered text must be preserved.

`@AppStorage` inside an `@Observable` class does not automatically forward changes to Observation.
Keep defaults observation at an appropriate boundary. Bloom persists domain data through its
SQLite `Store`; do not introduce SwiftData or CloudKit conventions here.
