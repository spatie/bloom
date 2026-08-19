import SwiftUI

/// One of the composer's per-turn pickers: model, effort, permission mode.
///
/// They are per turn rather than per app on purpose. A setting that lives in a preferences window
/// is a setting nobody changes per task, and per task is exactly the granularity these need.
struct ComposerOptionMenu: View {
    var options: [ComposerOption]
    var selection: String
    /// What the list is a list of, drawn as the menu's own heading. Short, because it sits above
    /// three or five one-word rows and a sentence over them would be the widest thing in the menu.
    var title: String
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
            // These were `Button { } label: { Label(text, systemImage: "checkmark") }`, which is a
            // shape AppKit has no room for: an item in an `NSMenu` draws its state marker in the
            // one column reserved for it, and an image supplied by the label is dropped on the
            // floor. So every one of these menus opened with no sign at all of what it was set to,
            // in an app whose whole footer is a row of settings. An inline picker hands the job to
            // the platform, which is how the sidebar's Filter menu has always drawn its own.
            Picker(title, selection: binding) {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.inline)
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
