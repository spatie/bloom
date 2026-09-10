# SwiftUI performance

Start with a measured symptom or a concrete repeated cost. Avoid rewriting every view according
to a fixed performance checklist.

- Keep view initialisers and `body` free of expensive synchronous work. Move I/O and costly
  transforms behind the appropriate model boundary and preserve cancellation and invalidation.
- Extract a subview when it creates a useful observation or identity boundary. A small private
  computed view property is fine for local composition; `@ViewBuilder` alone creates no boundary.
- Use stable IDs for lists and workspace rows. Preserve structural identity when a state change
  should update a view rather than destroy and recreate its state or native backing view.
- Avoid type erasure in hot paths when generics or a builder suffice, but require a concrete
  benefit before changing intentional `AnyView` boundaries.
- Choose lazy containers for large collections when they fit the required sizing and scrolling
  behaviour. Do not override Bloom's measured transcript layout without checking its constraints.
- Prefer format styles for display where possible. Cache expensive formatters only when needed.
- Keep derived collections cheap, or cache with explicit invalidation. Repeated filtering in
  `ForEach` can be costly; copying it into `@State` without synchronisation produces stale UI.
- Store built content when a container's content is static. Keep a closure when lazy evaluation,
  changing inputs or presentation timing requires it; these forms are not interchangeable.
