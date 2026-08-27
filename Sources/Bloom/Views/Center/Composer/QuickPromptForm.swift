import SwiftUI
import BloomCore

/// Writing a quick prompt, or changing one: a name, a mark, the words, and the two switches that
/// say what pressing it does.
///
/// One form for both jobs, because they are the same five fields. Editing adds Delete, on the left
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
/// **The picker is a popover hung off the well**, which is the third and last answer.
///
/// It was a hand-built overlay positioned off a measured well, and that covered the Text field and
/// the Save button. It was then a row in the stack, which covered nothing and cost the panel
/// exactly the picker's height: the form grew by three hundred points when the well was pressed
/// and shrank again when it was not, so pressing a small square resized the dialogue around it.
/// The owner's words on seeing it: that does not feel like macOS at all, and he is right. Nothing
/// on this platform makes a panel bigger to show a picker.
///
/// A popover is not the overlay that failed. It is an `NSPopover`: its own window above the sheet,
/// with an arrow saying which control opened it, closing on Escape or on a click outside without
/// this file arranging either, and costing the form no height at all. The measured well frame, the
/// measured content height and the reserve sum all went with the row, because a popover sizes
/// itself to what is in it.
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
    var onSave: @MainActor (QuickPrompt.Fields) -> Void
    /// Asks for the prompt to go. The panel owns the question, because the list can ask it too.
    var onDelete: @MainActor () -> Void

    @State private var name = ""
    @State private var symbol = QuickPrompt.defaultSymbol
    @State private var text = ""
    @State private var sendsImmediately = false
    @State private var opensNewChat = false
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

            behaviour

            buttons
        }
        .padding(Metrics.pane)
        // Command-Backspace is delete-to-start-of-line in a text box, and the menu bar had it
        // for Archive Workspace. See `FocusedValues.isTypingProse`.
        .focusedValue(\.isTypingProse, isNameFocused)
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
        // `.bounds` so the arrow points at the square rather than at the row it sits in, and
        // `.bottom` so the card hangs under the well the way a menu does, leaving the name field
        // beside it readable while an icon is chosen.
        .popover(
            isPresented: $isPickingMark,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            picker
        }
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

    /// The two switches, and one line saying what the pair of them will do.
    ///
    /// **Neither switch greys the other out**, and the sentence is why that is affordable. All
    /// four combinations mean something, including the quiet one: a new chat with the words
    /// waiting in its composer and nothing sent. Disabling the second switch while the first is
    /// off would forbid that, and a disabled control in a panel this small has nowhere to carry
    /// the reason it is disabled. So both stand alone and the line underneath reads the
    /// combination back, which is the thing somebody wants to know before pressing Save.
    ///
    /// The sentence is `QuickPromptDelivery`'s rather than this view's, because what a prompt does
    /// when it is chosen is a decision, and a decision taken in a view is one nothing can test.
    private var behaviour: some View {
        field("When you choose it") {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                toggle("Send it straight away", isOn: $sendsImmediately)
                toggle("Open it in a new chat tab", isOn: $opensNewChat)

                if let sentence = delivery.sentence {
                    Text(sentence)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// What the two switches add up to, which is what the line under them says.
    private var delivery: QuickPromptDelivery {
        QuickPromptDelivery(sendsImmediately: sendsImmediately, opensNewChat: opensNewChat)
    }

    /// One switch, drawn as a settings row rather than as SwiftUI lays a bare `Toggle` out.
    ///
    /// The label is on the left and the switch is at the trailing edge, which is where every
    /// switch on this Mac is, and the label is a target of its own, because a switch is a small
    /// thing to hit in a panel with the room for a whole row of words.
    ///
    /// The gesture is on the words and not on the row around them. A row-wide one sits behind the
    /// switch as well, and the two would both fire on the same click: the switch moves and the
    /// gesture moves it back, which reads as a control that does not work.
    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Metrics.spacing) {
            Text(title)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { isOn.wrappedValue.toggle() }

            Spacer(minLength: Metrics.spacing)

            // Labelled and then hidden, rather than built with an empty label: the words above are
            // drawn by this row, and VoiceOver still has to be told what the switch is called.
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
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
                    QuickPrompt.Fields(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        symbol: symbol,
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        sendsImmediately: sendsImmediately,
                        opensNewChat: opensNewChat
                    )
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
        // Off for a new prompt, and whatever the row says for one being edited. Cancelling writes
        // nothing, so opening the form and leaving it cannot move either switch.
        sendsImmediately = editing?.sendsImmediately ?? false
        opensNewChat = editing?.opensNewChat ?? false
        isNameFocused = true
    }
}
