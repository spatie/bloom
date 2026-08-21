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
extension View {
    func settingsForm() -> some View {
        formStyle(.grouped).modifier(SettingsLabelColumn())
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
/// label wants, taken before the column is applied to it. Applying the column changes what the
/// label is drawn in and not what it asked for, so the second pass measures the same numbers as
/// the first.
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
