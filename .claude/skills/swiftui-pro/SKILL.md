---
name: swiftui-pro
description: Write and review Bloom macOS SwiftUI views for data flow, accessibility, API correctness and measured performance.
license: MIT
metadata:
  author: Paul Hudson
  version: "1.1-bloom.1"
  adapted-for: Bloom
---

# SwiftUI in Bloom

Bloom targets macOS 26 and Swift 6.2, as declared in `Package.swift`. Follow `CLAUDE.md` for
architecture and file organisation. AppKit integration is intentional; do not apply iOS-only
rules or replace working bridges simply because a SwiftUI API exists.

For a review, report actionable defects with file locations and their effects. For an edit,
make the requested change. Avoid sweeping API migrations, fixed review templates and stylistic
findings without a concrete benefit.

Load only the references relevant to the code:

- [Data](references/data.md): state ownership, observation and bindings.
- [Views](references/views.md): composition, actions, previews and animation.
- [API](references/api.md): API migrations and platform availability.
- [Navigation](references/navigation.md): navigation state, sheets and dialogs.
- [Accessibility](references/accessibility.md): labels, keyboard access, contrast and motion.
- [Design](references/design.md): Bloom's design system and native Mac layout.
- [Performance](references/performance.md): identity, observation boundaries and expensive work.
- [Swift](references/swift.md): language and Foundation choices affecting UI code.
- [Hygiene](references/hygiene.md): project validation and handling sensitive data.
