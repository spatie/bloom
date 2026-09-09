---
name: swift-concurrency-pro
description: Write and review Bloom Swift concurrency code for actor isolation, task lifetime, cancellation and stream correctness.
license: MIT
metadata:
  author: Paul Hudson
  version: "1.0-bloom.1"
  adapted-for: Bloom
---

# Swift concurrency in Bloom

Check `Package.swift` and the actual target's compiler flags before inferring isolation. Bloom
uses Swift 6 language mode with a Swift 6.2 minimum toolchain; that alone does not enable default
MainActor isolation or `NonisolatedNonsendingByDefault`.

Preserve the intended task lifetime. Structured concurrency fits work owned by a caller;
unstructured tasks also have legitimate uses for UI actions and app-owned background services.
Audit their ownership, cancellation and errors rather than replacing them mechanically.

In reviews, report reproducible defects with file locations and effects. Make requested edits
directly. Do not silence sendability errors without establishing how shared state is protected.

Load only the references needed for the task:

- [Hotspots](references/hotspots.md): search targets for a concurrency review.
- [Swift 6.2 settings](references/new-features.md): isolation defaults and newer APIs.
- [Actors](references/actors.md): reentrancy and isolation boundaries.
- [Structured tasks](references/structured.md): task groups, errors and concurrency limits.
- [Unstructured tasks](references/unstructured.md): inheritance and ownership.
- [Cancellation](references/cancellation.md): cooperative cancellation and teardown.
- [Streams](references/async-streams.md): buffering, termination and consumer lifetime.
- [Bridging](references/bridging.md): continuations and sendability guarantees.
- [Interop](references/interop.md): GCD, locks, delegates and Combine.
- [Bug patterns](references/bug-patterns.md): recurring failure modes.
- [Diagnostics](references/diagnostics.md): compiler errors and boundary choices.
- [Testing](references/testing.md): deterministic concurrency checks and the shared testing guide.
