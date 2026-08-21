import SwiftUI

/// Every settings form in the app, and the label column its rows agree on.
///
/// One modifier rather than `.formStyle(.grouped)` at each of a dozen call sites, because the
/// grouped style is not the whole of what a settings form here is. A form also has to resolve the
/// width of its label column, and a form that had the style but not the column would be a pane
/// whose rows silently went back to being laid out the way described in `SettingsRowStyle`.
/// Putting both behind one name means a pane added later inherits both without anybody having to
/// know the second one exists.
///
/// The column is resolved per form, which is per tab, and that is deliberate. Sharing one column
/// across the whole window would let the longest label on the Agents pane push the fields on the
/// General pane half way across, which is the very thing this exists to stop. A tab is also the
/// most anybody sees at once, so a column agreed across tabs would line up rows that are never on
/// screen together at the cost of the ones that are.
///
/// The third thing it does is take the rule out from under the tab bar of both settings windows.
/// That rule belongs to the form rather than to the window, which is not where anybody looks for
/// it, so the whole of why is in `SettingsScrollPocket`.
extension View {
    func settingsForm() -> some View {
        formStyle(.grouped)
            .hidesScrollEdgeRule()
            .modifier(SettingsLabelColumn())
    }
}

/// Collects the natural width of every `SettingsRow` label in one form and hands the widest back
/// down, so the rows line up without anybody choosing a number.
///
/// A measured column rather than a constant. The labels are not a fixed list: the Agents pane
/// builds its rows from whatever `AgentCatalog` reports, and a constant wide enough for the worst
/// of those would be a channel down every other pane. Measured, each pane is exactly as wide as
/// its own longest label and no wider.
///
/// It settles in one extra pass and cannot oscillate, because what a row reports is the width its
/// label wants and not the width it was given. That distinction is the whole of it, and it is
/// `SettingsRowStyle` that holds the line: without a fixed ideal width a label reports whatever it
/// was squeezed to, which turns this into a ratchet that only tightens and can never widen for a
/// row that appears later. `Colour` arriving as `Colou` over `r` was that bug. See the comment on
/// the label there for the measurements.
struct SettingsLabelColumn: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.settingsLabelColumn, width)
            .onPreferenceChange(SettingsLabelWidth.self) { width = $0 }
    }
}

/// The width one label wants, on its way up to the form.
struct SettingsLabelWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension EnvironmentValues {
    /// The width the labels in this form have settled on, or zero before the first pass, which is
    /// a row's cue to take its label's natural width for one frame.
    @Entry var settingsLabelColumn: CGFloat = 0
}
