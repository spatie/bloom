import SwiftUI

/// The rows inside a composer picker, as a view of their own.
///
/// Split out of `ComposerOptionMenu` so the same items can be built somewhere other than under a
/// `Menu` label, which is what `MenuProbe` needs: an `NSHostingMenu` is handed menu content, not a
/// menu. `CenterPaneMenu` and `WorkspaceMenuItems` are already shaped this way and for the same
/// reason, so a photograph of a menu cannot show an item the app does not have.
struct ComposerOptionItems: View {
    var options: [ComposerOption]
    var sections: [ComposerModelSection]?
    var footnote: String?
    var selection: String
    var heading: String?
    /// Doubles as the picker's own name for VoiceOver when there is no heading written over it.
    var help: String
    var onSelect: @MainActor (String) -> Void

    var body: some View {
        // A `Picker` rather than a column of buttons, and the reason is the tick.
        //
        // These were `Button { } label: { Label(text, systemImage: "checkmark") }`, and a symbol
        // handed to a button's label that way is dropped: the menu came up as three bare names
        // with no marker on any of them, in an app whose whole footer is a row of settings. The
        // state column of an `NSMenu` item is the menu's to draw and not the label's, and an
        // inline picker is what asks the platform to draw it. The sidebar's Filter menu has always
        // been built this way.
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

        if let footnote {
            Divider()
            // Plain text in a menu draws as a disabled row, which is what this is: something to
            // read, not something to press.
            Text(footnote)
        }
    }

    /// The picker writes back through the caller rather than into storage of its own, because
    /// where the choice lives is the caller's business: a session row in a conversation, a value
    /// carried into a workspace that does not exist yet in the create window.
    private var binding: Binding<String> {
        Binding(get: { selection }, set: { id in MainActor.assumeIsolated { onSelect(id) } })
    }
}
