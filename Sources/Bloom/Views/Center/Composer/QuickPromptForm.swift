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
///
/// **The name and the mark are one row.** They were two groups, with eighteen symbols laid out
/// under their own label, which is a third of the form spent on the smallest decision in it and a
/// hard ceiling on how many marks there could ever be. A square well with the current mark in it,
/// and the name filling the rest of the row, is the shape of the same row in There There, and it
/// puts the choice behind one press instead of in front of everybody who only wanted to rename
/// something.
struct QuickPromptForm: View {
    /// The prompt being changed, or nil when this is a new one.
    var editing: QuickPrompt?
    /// What a new prompt is called before anybody types: whatever was in the search field, because
    /// somebody who searched for a prompt they have not written yet has just said what to call it.
    var suggestedName: String = ""
    /// Whether the form opens with the picker already up.
    ///
    /// False everywhere but `QuickPromptGallery`, which renders this form offscreen and cannot
    /// press a button to open anything. The panel shipped four times with something wrong with it
    /// that one look would have caught, so the state that has to be looked at has to be reachable
    /// without a click.
    var startsPickingMark = false
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
    /// Whether the icon picker is up.
    @State private var isPickingMark = false
    /// Where the well is, in the form's own coordinates, so the picker can be hung off it rather
    /// than off the row around it. Measured rather than worked out from the spacing scale, because
    /// a form whose label heights are guessed at is a picker that drifts a point or two off its
    /// well the first time a rung of `Typo` moves.
    @State private var wellFrame: CGRect = .zero
    /// How tall the form is with nothing hanging off it. See `pickerReserve`.
    @State private var contentHeight: CGFloat = 0

    @FocusState private var isNameFocused: Bool

    /// Three lines of the shipped prompt with room for a fourth. It was 92, which fitted the text
    /// exactly and left the box looking full before anything was typed.
    private static let textHeight: CGFloat = 108
    /// The well, sized to the field beside it so the row reads as one control rather than as a
    /// button that happens to be next to one.
    private static let wellSize: CGFloat = 22
    /// The mark inside it, set well under the well so the plate reads as a plate.
    private static let wellPoints: CGFloat = 15
    /// The name the well's position is measured in.
    private static let formSpace = "quickPromptForm"

    var body: some View {
        // `Metrics.pane` and `gutter` rather than the tighter rungs the rest of this panel uses.
        // A list is scanned and wants to be dense; a form is filled in, and at the panel's spacing
        // the three labels sat on top of their controls and the whole card read as cramped.
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            heading

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
        .coordinateSpace(.named(Self.formSpace))
        // Measured before the room for the picker is added, so the one cannot feed the other.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .padding(.bottom, pickerReserve)
        .padding(Metrics.pane)
        // Over the whole panel rather than over the fields, so a click on the padding closes the
        // picker too. A popover would have had that for nothing; this card is inside the panel, so
        // it has to be given.
        .overlay(alignment: .topLeading) { picker }
        .onAppear(perform: prepare)
        // Escape leaves the form and goes back to the list, rather than closing the whole panel and
        // losing what was typed with it. While the picker is up it has Escape first, and gives it
        // back on the second press.
        .onExitCommand { isPickingMark ? closePicker() : onCancel() }
    }

    private var heading: some View {
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
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.formSpace))
        } action: { wellFrame = $0 }
    }

    /// The picker, hung under the well, over a layer that swallows the click that dismisses it.
    @ViewBuilder
    private var picker: some View {
        if isPickingMark {
            ZStack(alignment: .topLeading) {
                // Not `Color.clear` on its own, which takes no clicks at all.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closePicker() }

                QuickPromptMarkPicker(
                    selection: symbol,
                    onChoose: { mark in
                        symbol = mark.stored
                        closePicker()
                    },
                    onClose: closePicker
                )
                // The form's own padding, because this layer is outside it and the well was
                // measured inside it.
                .offset(
                    x: wellFrame.minX + Metrics.pane,
                    y: wellFrame.maxY + Metrics.pane + Metrics.spacingSmall
                )
            }
        }
    }

    /// How much taller the panel has to be while the picker is up.
    ///
    /// **The card cannot hang past the panel's edge, because it is inside it.** A `.popover` of its
    /// own would float free, and would also take the whole panel with it on the first click: see
    /// `QuickPromptMarkPicker`. So the form grows by exactly what is missing and by nothing when
    /// nothing is, which is most of the time only the last thirty or so points.
    private var pickerReserve: CGFloat {
        guard isPickingMark, contentHeight > 0 else { return 0 }
        let need = wellFrame.maxY + Metrics.spacingSmall + QuickPromptMarkPicker.height
        return max(0, need - contentHeight)
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
