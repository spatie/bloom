import SwiftUI

/// The composer's per-turn pickers whose rows describe themselves: the model and the effort.
///
/// They are per turn rather than per app on purpose. A setting that lives in a preferences window
/// is a setting nobody changes per task, and per task is exactly the granularity these need.
///
/// **It used to be all four, and it carried a footnote so that two of them could say what a row
/// would do.** An `NSMenu` row is one line with no room under it, so the permission mode and the
/// output style printed the selected row's sentence at the foot of the menu, which is after the
/// choice rather than before it. Those two are `ComposerOptionPicker` now, with the sentence on
/// the row it belongs to. What is left here is the two pickers a menu suits: Opus 5 is a name and
/// Extra high is a point on a scale, and neither has anything to add underneath itself.
///
/// The rows were `ComposerOptionItems`, a view of their own so that `MenuProbe` could hand them to
/// an `NSHostingMenu` and photograph the real ones. The one part that used it was the output style
/// picker, which is not a menu any more, and there is no probe part for the model or the effort;
/// a second file kept for a caller that no longer exists is a second place to look. The rows are
/// back inside the menu that draws them, and `ComposerPickerGallery` is where these are looked at
/// now, offscreen and in both appearances.
struct ComposerOptionMenu: View {
    var options: [ComposerOption]
    /// When set, the rows are grouped under headings instead of run together. The model menu is
    /// the one that needs it: with two backends a flat list of five names says nothing about which
    /// agent each name belongs to, and picking a name is picking an agent.
    var sections: [ComposerModelSection]?
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
            rows
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

    /// A `Picker` rather than a column of buttons, and the reason is the tick.
    ///
    /// These were `Button { } label: { Label(text, systemImage: "checkmark") }`, and a symbol
    /// handed to a button's label that way is dropped: the menu came up as bare names with no
    /// marker on any of them, in an app whose whole footer is a row of settings. The state column
    /// of an `NSMenu` item is the menu's to draw and not the label's, and an inline picker is what
    /// asks the platform to draw it. The sidebar's Filter menu has always been built this way.
    @ViewBuilder
    private var rows: some View {
        let picker = Picker(heading ?? help, selection: binding) {
            if let sections {
                // One `Picker` with sections inside it rather than a picker per section: the tick
                // belongs to the selection, and two pickers would each draw one.
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }
            } else {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
        }
        .pickerStyle(.inline)

        // `labelsHidden` takes the heading off while leaving the picker its own name, so a menu
        // with nothing written over it still announces itself to VoiceOver.
        if heading == nil {
            picker.labelsHidden()
        } else {
            picker
        }
    }

    /// The picker writes back through the caller rather than into storage of its own, because
    /// where the choice lives is the caller's business: a session row in a conversation, a value
    /// carried into a workspace that does not exist yet in the create window.
    private var binding: Binding<String> {
        Binding(get: { selection }, set: { id in MainActor.assumeIsolated { onSelect(id) } })
    }

    private var label: String {
        ComposerOption.label(for: selection, in: sections?.flatMap(\.options) ?? options)
    }
}
