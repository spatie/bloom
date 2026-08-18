import SwiftUI

/// One of the composer's per-turn pickers: model, effort, permission mode.
///
/// They are per turn rather than per app on purpose. A setting that lives in a preferences window
/// is a setting nobody changes per task, and per task is exactly the granularity these need.
struct ComposerOptionMenu: View {
    var options: [ComposerOption]
    var selection: String
    var systemImage: String
    var tint: Color = Palette.textSecondary
    /// Drops the word and keeps the glyph, for a footer that has run out of room. The tooltip and
    /// the accessibility label still say which picker this is, so nothing is lost but the width.
    var isCompact: Bool = false
    var help: String
    var onSelect: @MainActor (String) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    // A real checkmark rather than a text glyph, so the menu reads the way every
                    // other Mac menu does, to the eye and to VoiceOver.
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            ComposerControlLabel(
                systemImage: systemImage,
                text: isCompact ? nil : label,
                tint: tint,
                showsMenuIndicator: true
            )
        }
        // `.button` plus `.plain` is the only combination that lets the label keep its own height.
        // The indicator is hidden because the label already draws one on the row's baseline.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Vertically fixed only. Fixed in both axes the three pickers were incompressible, and an
        // HStack whose children all refuse to shrink overflows rather than truncating: in a split
        // pane the model picker fell off the leading edge while the attach and send buttons fell
        // off the trailing one. `ComposerFooterView` drops the words first; this is what lets what
        // is left give a few more points before anything is pushed off the row.
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(label)
    }

    private var label: String {
        ComposerOption.label(for: selection, in: options)
    }
}
