# Accessibility on macOS

- Give actionable controls meaningful accessible names. Prefer a labelled `Button` or `Menu`,
  using `.labelStyle(.iconOnly)` when the visual should be just an icon. An explicit
  `accessibilityLabel` can also make a custom control accessible; visible text is not required.
- Use native controls for actions so keyboard and assistive-technology behaviour comes with them.
  Gestures are appropriate for selection, dragging or spatial input; a button trait alone does
  not give a custom gesture keyboard activation.
- Hide decorative images from accessibility and describe meaningful images. Verify labels and
  grouping in context rather than assuming an asset name is a useful spoken description.
- Preserve keyboard focus, shortcuts and a usable focus order through sheets and custom panes.
- Respect Reduce Motion and Increase Contrast. Avoid conveying state by colour alone.
- Prefer semantic text styles or Bloom's existing typography. Check truncation and readability
  across window sizes and supported accessibility settings. Do not impose iOS Dynamic Type or
  touch-target assumptions on native Mac controls.
