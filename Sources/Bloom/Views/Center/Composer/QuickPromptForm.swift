import SwiftUI
import BloomCore

/// Writing a quick prompt, or changing one: a name, a mark and the words. Nothing else.
///
/// One form for both jobs, because they are the same three fields. Editing adds Delete, on the left
/// of the row Save is on, which is where a destructive button goes in a Mac form and the only place
/// this one lives. It asks before it deletes: see `QuickPromptDeletion`.
///
/// It is drawn inside the panel the list was in rather than in a sheet of its own: the list and the
/// form are two states of one popover, so choosing a prompt and editing one never involve two
/// floating windows arguing about which has the keyboard.
///
/// **The name and the mark are one row.** They were two groups, with eighteen symbols laid out
/// under their own label, which is a third of the form spent on the smallest decision in it and a
/// hard ceiling on how many marks there could ever be. A square well with the current mark in it,
/// and the name filling the rest of the row, is the shape of the same row in There There, and it
/// puts the choice behind one press instead of in front of everybody who only wanted to rename
/// something.
///
/// **The picker opens into a gap rather than over the form**, which is what the second round of
/// this panel got wrong. It used to be an overlay positioned off a measured well, with the panel
/// padded at the foot by whatever the card overhung by; that arithmetic was right and the result
/// was still a card sitting on top of the Text field and the Save button. A row in the stack costs
/// the panel exactly the same height and covers nothing, and it takes the measured well frame, the
/// measured content height and the reserve sum with it.
struct QuickPromptForm: View {
    /// The prompt being changed, or nil when this is a new one.
    var editing: QuickPrompt?
    /// What a new prompt is called before anybody types: whatever was in the search field, because
    /// somebody who searched for a prompt they have not written yet has just said what to call it.
    var suggestedName: String = ""
    /// Whether the form opens with the picker already up.
    ///
    /// False everywhere but `QuickPromptGallery`, which renders this form offscreen and cannot
    /// press a button to open anything. The panel shipped five times with something wrong with it
    /// that one look would have caught, so the state that has to be looked at has to be reachable
    /// without a click.
    var startsPickingMark = false
    var onCancel: @MainActor () -> Void
    var onSave: @MainActor (_ name: String, _ symbol: String, _ text: String) -> Void
    /// Asks for the prompt to go. The panel owns the question, because the list can ask it too.
    var onDelete: @MainActor () -> Void

    @State private var name = ""
    @State private var symbol = QuickPrompt.defaultSymbol
    @State private var text = ""
    /// Whether the fields have been filled from `editing` yet. A `task` rather than `onAppear`
    /// would run again when the panel is rebuilt under an open form and would throw away what has
    /// been typed since.
    @State private var isPrepared = false
    /// Whether the icon picker is up.
    @State private var isPickingMark = false

    @FocusState private var isNameFocused: Bool

    /// Three lines of the shipped prompt with room for a fourth. It was 92, which fitted the text
    /// exactly and left the box looking full before anything was typed.
    private static let textHeight: CGFloat = 108
    /// The well, sized to the field beside it so the row reads as one control rather than as a
    /// button that happens to be next to one.
    private static let wellSize: CGFloat = 22
    /// The mark inside it, set well under the well so the plate reads as a plate.
    private static let wellPoints: CGFloat = 15

    var body: some View {
        // `Metrics.pane` between the groups, which is the widest rung there is, and the owner asked
        // for it twice. The form was on `gutter` and read as cramped: it is filled in rather than
        // scanned, and a panel four groups tall at twelve points apart is a wall of controls. The
        // labels inside a group stay tight, so the wide gap is what says where one group ends.
        VStack(alignment: .leading, spacing: Metrics.pane) {
            heading

            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                field("Name and icon") {
                    HStack(spacing: Metrics.spacing) {
                        well

                        TextField("Run the tests", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(Typo.body)
                            .focused($isNameFocused)
                            .accessibilityLabel("Quick prompt name")
                    }
                }

                if isPickingMark {
                    picker
                }
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
        }
        .padding(Metrics.pane)
        // Behind the form rather than over it, which is the whole of why this is a `background`.
        // An overlay took the clicks meant for the fields under it; a background takes only the
        // ones nothing else wanted, which is exactly the click on the panel's own padding that
        // ought to put the picker away.
        .background {
            if isPickingMark {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closePicker() }
            }
        }
        .onAppear(perform: prepare)
        // Escape leaves the form and goes back to the list, rather than closing the whole panel and
        // losing what was typed with it. While the picker is up it has Escape first, and gives it
        // back on the second press.
        .onExitCommand { isPickingMark ? closePicker() : onCancel() }
    }

    private var heading: some View {
        // `spacingSmall`, not `spacingHair`. At one point the subtitle sat on the ascenders of the
        // title above it and the two read as one wrapped line, which is what the owner meant by the
        // heading sitting almost on its subtitle.
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
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

    /// The square that opens the picker, showing what the prompt is marked with now.
    private var well: some View {
        Button {
            isPickingMark.toggle()
        } label: {
            QuickPromptMarkView(
                stored: symbol, points: Self.wellPoints, tint: Palette.textPrimary
            )
            .frame(width: Self.wellSize, height: Self.wellSize)
            .background(
                Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .strokeBorder(
                        isPickingMark ? Palette.accent : Palette.border,
                        lineWidth: Metrics.hairline
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an icon or an emoji")
        .accessibilityLabel("Quick prompt icon")
    }

    /// The picker, under the well and narrower than the form, so it reads as a card hung off the
    /// square that opened it rather than as a second panel the width of the first.
    private var picker: some View {
        QuickPromptMarkPicker(
            selection: symbol,
            onChoose: { mark in
                symbol = mark.stored
                closePicker()
            },
            onClose: closePicker
        )
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

    /// Shuts the picker and puts the keyboard back where it was. The picker's own field took first
    /// responder when it opened, and a form whose caret is in a field that no longer exists is a
    /// form the next keystroke goes nowhere in.
    private func closePicker() {
        isPickingMark = false
        isNameFocused = true
    }

    private func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        isPickingMark = startsPickingMark
        name = editing?.name ?? suggestedName
        symbol = editing.map { QuickPrompt.resolvedSymbol($0.symbol) } ?? QuickPrompt.defaultSymbol
        text = editing?.text ?? ""
        isNameFocused = true
    }
}
