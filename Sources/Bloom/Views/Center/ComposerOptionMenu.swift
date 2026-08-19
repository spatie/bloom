import SwiftUI

/// One of the composer's per-turn pickers: model, effort, permission mode.
///
/// They are per turn rather than per app on purpose. A setting that lives in a preferences window
/// is a setting nobody changes per task, and per task is exactly the granularity these need.
struct ComposerOptionMenu: View {
    var options: [ComposerOption]
    var selection: String
    /// What the list is a list of, drawn as the menu's own heading, or nil when the items name
    /// their own category and a heading over them would only be a word to read past.
    ///
    /// Effort is Low through Max and permission mode is Ask through Plan: bare adjectives and
    /// bare verbs that say nothing about what they are settings for. Models are Opus 5 and Sonnet
    /// 5, which are names, and the chip the menu opened from is already showing one of them.
    var heading: String?
    var systemImage: String
    var tint: Color = Palette.textSecondary
    /// Drops the word and keeps the glyph, for a footer that has run out of room. The tooltip and
    /// the accessibility label still say which picker this is, so nothing is lost but the width.
    var isCompact: Bool = false
    var help: String
    var onSelect: @MainActor (String) -> Void

    var body: some View {
        Menu {
            // A `Picker` rather than a column of buttons, and the reason is the tick.
            //
            // These were `Button { } label: { Label(text, systemImage: "checkmark") }`, and a
            // symbol handed to a button's label that way is dropped: the menu came up as three
            // bare names with no marker on any of them, in an app whose whole footer is a row of
            // settings. The state column of an `NSMenu` item is the menu's to draw and not the
            // label's, and an inline picker is what asks the platform to draw it. The sidebar's
            // Filter menu has always been built this way.
            items
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

    /// The rows, headed or not. `labelsHidden` takes the heading off while leaving the picker its
    /// own name, so a menu with nothing written over it still announces itself to VoiceOver.
    @ViewBuilder
    private var items: some View {
        let picker = Picker(heading ?? help, selection: binding) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.inline)

        if heading == nil {
            picker.labelsHidden()
        } else {
            picker
        }
    }

    /// The picker writes back through the caller rather than into storage of its own, because
    /// where the choice lives is the caller's business: a session row in a conversation, a value
    /// carried into a workspace that does not exist yet in the create sheet.
    private var binding: Binding<String> {
        Binding(get: { selection }, set: { id in MainActor.assumeIsolated { onSelect(id) } })
    }

    private var label: String {
        ComposerOption.label(for: selection, in: options)
    }
}
