import SwiftUI

/// One row of a settings form: a short label, and the control it belongs to, side by side.
///
/// This exists because `LabeledContent`'s own macOS style does not put them side by side. Measured
/// on macOS 26: inside a grouped `Form` it pins the control to the trailing edge of the row and
/// caps that trailing column at about 376 points, so the control starts at 45 per cent of the row
/// whatever the label says. A 35 point `Name` was followed by 256 points of nothing and then a
/// field, and `Mark`'s three small buttons floated in the middle of the window with empty ground
/// on both sides. The label length has nothing to do with it: `Name` and a label six times longer
/// both put the field at the same 291 points in a 640 point window.
///
/// That layout is right for the rows the framework applies it to on its own. A `Toggle`'s switch
/// and a `Picker`'s pop up belong at the trailing edge of a Mac settings row, and both of those
/// are left exactly as they are: this style is set on the row rather than on the form precisely so
/// it cannot reach them. Setting it on the form does reach them, measured, and it drags a switch
/// away from the edge and wraps its label to two lines to make room.
///
/// What is left is the case the framework gets wrong: a label with a field, a row of buttons or a
/// set of swatches beside it, where the content is left aligned inside a right hand column and so
/// leaves a channel on both sides. Those rows are these.
///
/// **A row whose leading half is not a short label is not one of these.** A settings file's path
/// with an `Open` button after it, or a sentence explaining that macOS is blocking notifications,
/// are content in their own right rather than labels, and they join the column only to blow it out
/// for every other row in the pane. They are ordinary rows with a `Spacer` and read correctly that
/// way. See `RepoSettingsView.filesSection`.
struct SettingsRow<Label: View, Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        LabeledContent(content: content, label: label)
            .labeledContentStyle(SettingsRowStyle())
    }
}

extension SettingsRow where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, label: { Text(title) })
    }
}

extension SettingsRow where Label == Text, Content == Text {
    /// The read only case, where the value is a string and nothing can be done to it.
    init(_ title: String, value: String) {
        self.init(content: { Text(value) }, label: { Text(title) })
    }
}

/// Lays the label out in the column the form has settled on and puts the content straight after it.
///
/// First text baseline rather than centre, because the tallest content in these rows is a stack
/// two or three lines high and a label centred against it sits opposite the middle line rather
/// than against the thing it names.
///
/// The content's alignment is reset on the way in. A grouped form puts a trailing
/// `multilineTextAlignment` into the environment for its value column, which is what set a text
/// field's own text flush right and left every wrapped sentence ragged on the left. Reset here,
/// once, rather than at each of the call sites that had grown their own copy of the workaround.
private struct SettingsRowStyle: LabeledContentStyle {
    @Environment(\.settingsLabelColumn) private var column

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
            configuration.label
                // Never wrapped, and this is load bearing rather than tidiness.
                //
                // `Colour` was arriving as `Colou` over `r`. A label with no `fixedSize` is laid
                // out against whatever width it is offered, so the width it reports back is the
                // width it was squeezed to and not the width it wants, and that turns the
                // measurement below into a ratchet that only ever tightens. Two ways in, both
                // real. A row whose content is rigid and wide, and the swatches are eleven of
                // them plus a capsule, leaves its label a narrow offer on the pass where the
                // column is still zero, so the column settles on a wrapped width and every later
                // pass hands that same too-narrow width back. And a row that appears later,
                // which the colour row does because it is only there when the mark is initials,
                // is measured against a column that is already set: wider than the column, it
                // wraps, reports the column's own width, and the column can never grow to fit it.
                // The second is the worse of the two, because any conditional row added after
                // this one inherits it.
                //
                // With the ideal width pinned, what travels up is what the label wants, the
                // column is the widest of those, and no label is ever offered less than it needs.
                .fixedSize(horizontal: true, vertical: false)
                // Measured before the column is applied, so what travels up is the width this
                // label wants rather than the width it has been given. See `SettingsLabelColumn`.
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SettingsLabelWidth.self, value: proxy.size.width)
                })
                .frame(width: column > 0 ? column : nil, alignment: .leading)

            configuration.content
                .multilineTextAlignment(.leading)

            // Content that wants the whole width still takes it, because a `TextField` asks for it
            // and this yields. Content that does not is left beside its label instead of being
            // stretched across the pane.
            Spacer(minLength: 0)
        }
    }
}
