# API choices

Check macOS availability and the selected SDK before applying API advice. Prefer modern forms
in changed code, but do not turn a focused edit into a migration of working integration code.

- Prefer `foregroundStyle`, `clipShape(.rect(cornerRadius:))`, and closure-based `overlay` when
  they express the same result. Some older forms are deprecated; check the actual overload.
- Prefer zero-argument or old/new-value `onChange` over its deprecated one-value form.
- Use `NavigationStack`, `NavigationSplitView` and the modern `Tab` API where those containers
  match the screen. Bloom also has intentional custom workspace and window navigation.
- Use `@Entry` for new environment keys when appropriate; preserving a typed existing key is
  not itself a correctness problem.
- A `GeometryReader` is valid when geometry is actually needed. Consider `Layout`,
  `containerRelativeFrame` or `visualEffect` when they express the required behaviour more directly.
- Prefer text interpolation over concatenating `Text` values; preserve localisation semantics.
- Swift 6.2 supports random-access `enumerated()` for suitable collections. Stable model IDs,
  rather than offsets, still matter when rows can move or be deleted.
- Generated asset symbols require build support. Bloom builds through SwiftPM and custom scripts;
  do not assume Xcode's asset-symbol generation is enabled.
- SwiftUI's WebKit views can replace some wrappers on macOS 26. Compare delegate, navigation and
  embedding requirements before changing Bloom's existing web view bridge.
- Import `Combine` explicitly when using Combine APIs. Do not infer its deprecation from the
  availability of Observation or async sequences.
