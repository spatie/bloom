# View composition and animation

Extract subviews by responsibility and useful observation boundaries. Small private view helpers
are fine when they belong to the same subject. Follow Bloom's one-subject-per-file guidance rather
than flagging every file with multiple related types.

Keep subprocess calls and testable decisions out of views, as required by `CLAUDE.md`. Actions can
call model methods; short forwarding closures do not need another layer just for appearance.

Choose `TextField(axis: .vertical)` for suitable short multiline input. Use `TextEditor` or Bloom's
existing native editor for editing features it supplies; a placeholder alone does not decide this.
Use typed selection values where they represent a domain identity, and `#Preview` for new previews.

For animations, scope `.animation(..., value:)` to the changing value or use `withAnimation`.
Use animation completion for a dependent next phase; use phase/keyframe animation when it better
models the interaction. Fixed sleeps do not synchronise with animation completion. Respect
Reduce Motion and verify that animated transitions preserve view and focus identity.

`@Animatable` can reduce custom animation boilerplate when supported by the SDK, but existing
`animatableData` is valid. Avoid changing it merely to adopt a macro.
