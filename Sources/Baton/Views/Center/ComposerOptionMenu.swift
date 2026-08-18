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
                text: label,
                tint: tint,
                showsMenuIndicator: true
            )
        }
        // `.button` plus `.plain` is the only combination that lets the label keep its own height.
        // The indicator is hidden because the label already draws one on the row's baseline.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(label)
    }

    private var label: String {
        ComposerOption.label(for: selection, in: options)
    }
}
