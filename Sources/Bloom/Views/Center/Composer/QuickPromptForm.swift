import SwiftUI
import BloomCore

/// Writing a quick prompt, or changing one: a name, a mark and the words. Nothing else.
///
/// One form for both jobs, because they are the same three fields. Editing adds Delete, on the left
/// of the row Save is on, which is where a destructive button goes in a Mac form and the only place
/// this one lives. Deleting something you wrote is worth one deliberate trip rather than one stray
/// click in a list you opened to pick from.
///
/// It is drawn inside the panel the list was in rather than in a sheet of its own: the list and the
/// form are two states of one popover, so choosing a prompt and editing one never involve two
/// floating windows arguing about which has the keyboard.
struct QuickPromptForm: View {
    /// The prompt being changed, or nil when this is a new one.
    var editing: QuickPrompt?
    /// What a new prompt is called before anybody types: whatever was in the search field, because
    /// somebody who searched for a prompt they have not written yet has just said what to call it.
    var suggestedName: String = ""
    var onCancel: @MainActor () -> Void
    var onSave: @MainActor (_ name: String, _ symbol: String, _ text: String) -> Void
    var onDelete: @MainActor () -> Void

    @State private var name = ""
    @State private var symbol = QuickPrompt.defaultSymbol
    @State private var text = ""
    /// Whether the fields have been filled from `editing` yet. A `task` rather than `onAppear`
    /// would run again when the panel is rebuilt under an open form and would throw away what has
    /// been typed since.
    @State private var isPrepared = false

    @FocusState private var isNameFocused: Bool

    /// Three lines of the shipped prompt with room for a fourth. It was 92, which fitted the text
    /// exactly and left the box looking full before anything was typed.
    private static let textHeight: CGFloat = 108

    var body: some View {
        // `Metrics.pane` and `gutter` rather than the tighter rungs the rest of this panel uses.
        // A list is scanned and wants to be dense; a form is filled in, and at the panel's spacing
        // the three labels sat on top of their controls and the whole card read as cramped.
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            heading

            field("Name") {
                TextField("Run the tests", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.body)
                    .focused($isNameFocused)
                    .accessibilityLabel("Quick prompt name")
            }

            field("Icon") {
                QuickPromptSymbolGrid(symbol: $symbol)
            }

            field("Text") {
                TextEditor(text: $text)
                    .font(Typo.body)
                    .scrollContentBackground(.hidden)
                    .padding(Metrics.spacingSmall)
                    .frame(height: Self.textHeight)
                    .background(
                        Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
                    // A hand-built box gets no focus ring from AppKit, so it gets the same border
                    // `PromptEditor` draws for the same reason.
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                            .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
                    }
                    .accessibilityLabel("Quick prompt text")
            }

            buttons
                .padding(.top, Metrics.spacingSmall)
        }
        .padding(Metrics.pane)
        .onAppear(perform: prepare)
        // Escape leaves the form and goes back to the list, rather than closing the whole panel and
        // losing what was typed with it.
        .onExitCommand(perform: onCancel)
    }

    private var heading: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: QuickPrompt.resolvedSymbol(symbol))
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
                .background(
                    Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )

            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                Text(editing == nil ? "New quick prompt" : "Edit quick prompt")
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                Text(
                    editing == nil
                        ? "It is available in every workspace."
                        : "Changes apply everywhere. Nothing already sent is affected."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Metrics.spacingWide) {
            if editing != nil {
                // `role: .destructive` alone leaves a bordered button on macOS drawn in the
                // ordinary label colour, so it read as a third neutral button beside Cancel and
                // Save. Coloured explicitly, which is what `RepoSettingsView` does for Remove
                // Project and for the same reason.
                Button(role: .destructive, action: onDelete) {
                    Text("Delete").foregroundStyle(Palette.negative)
                }
                .accessibilityLabel("Delete this quick prompt")
                Spacer(minLength: Metrics.spacing)
            } else {
                Spacer(minLength: Metrics.spacing)
            }

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Save") {
                onSave(
                    name.trimmingCharacters(in: .whitespacesAndNewlines),
                    symbol,
                    text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .keyboardShortcut(.defaultAction)
            // The words are the whole of a quick prompt. A name is not: an unnamed one is listed
            // and searched by its own first line. See `QuickPrompt.resolvedName`.
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }

    private func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        name = editing?.name ?? suggestedName
        symbol = editing.map { QuickPrompt.resolvedSymbol($0.symbol) } ?? QuickPrompt.defaultSymbol
        text = editing?.text ?? ""
        isNameFocused = true
    }
}
