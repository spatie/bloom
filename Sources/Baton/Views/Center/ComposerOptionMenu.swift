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
            Label(ComposerOption.label(for: selection, in: options), systemImage: systemImage)
                .font(Typo.caption)
                .foregroundStyle(tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}
