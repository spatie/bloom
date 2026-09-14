# Native Mac design

Reuse the typography, colours, dimensions and animation values in `Sources/Bloom/Design`.
Follow nearby panes before adding another token system or restyling the entire app.

- Base layout on the available window or container, not global screen bounds. Check the supported
  minimum window size and resizing, especially for transcript, terminal and inspector panes.
- Native Mac control sizes and keyboard interaction apply. An iOS 44-point touch-area rule is
  not a universal minimum for macOS buttons.
- Use `Label`, hierarchical foreground styles and `LabeledContent` where they fit. Preserve
  Bloom's established custom empty states when they provide useful guidance.
- Fixed spacing, font weights and dimensions can be intentional design choices. Report concrete
  clipping, contrast, alignment or usability problems instead of banning numeric constants.
- Use SwiftUI colours or appropriate AppKit semantic colours. AppKit is part of this app's
  platform integration, not a fallback to remove automatically.
- Check focused/unfocused windows, light/dark appearance and accessibility settings when the
  change affects those states. Use headless or offscreen checks within the session's authorisation.
