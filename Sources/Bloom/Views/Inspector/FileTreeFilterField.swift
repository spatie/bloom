import SwiftUI

/// The strip above the worktree tree that narrows it to what somebody is looking for.
///
/// **While this field has the keyboard it owns every character, and the tree's type-select does
/// not get a look at any of them.** Both answer a typed letter with "jump to what that spells",
/// and a pane holding two of those is a pane where the reader cannot say where their next letter
/// will land. Nothing here enforces that and nothing needs to: a window has one first responder,
/// the tree's is `ListKeyboardHost` and this is an ordinary field, so whichever holds it holds the
/// letters. What matters is the other direction, and it is `FileTreeView` that keeps it: the tree
/// claims the responder only when a row is activated, which is a click or a Return and never
/// something that happens on its own. That is the failure `HomeListKeyboard` is written down from,
/// where a list woke from a `.task` and pulled the caret out of the window's search field between
/// two letters of a word.
///
/// A banner rather than a floating field, laid out like `BrowserFindBar`: a glyph, the field, and
/// a way to clear it, in a strip with a hairline under it.
struct FileTreeFilterField: View {
    @Binding var query: String
    /// Escape. See `FileTreeView.escape` for the two steps it has.
    var onEscape: @MainActor () -> Void
    /// Return, which hands the keyboard to the tree.
    ///
    /// The down arrow does not, and cannot from here: a focused `TextField` reads both arrows
    /// inside its own field editor and nothing outside sees the event. `MenuSearchField` is the
    /// way out if the arrows are ever wanted here too, and its head is where that is written up.
    var onReturn: @MainActor () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "magnifyingglass")
                .font(Typo.micro)
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: InspectorLayout.glyphWidth, alignment: .leading)
                .accessibilityHidden(true)

            TextField("Filter files", text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($isFocused)
                .autocorrectionDisabled()
                .onSubmit(onReturn)
                // Read here rather than by the pane around it, because the field is what holds the
                // keyboard at the moment Escape is pressed.
                .onExitCommand(perform: onEscape)
                .accessibilityLabel("Filter files")

            if !query.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
    }

    /// The caret stays here afterwards. Somebody who clears a filter is usually about to type a
    /// different one, and sending the keyboard to the tree would make them click twice to do it.
    private func clear() {
        query = ""
        isFocused = true
    }
}
