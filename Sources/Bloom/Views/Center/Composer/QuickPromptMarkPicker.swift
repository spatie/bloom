import SwiftUI
import BloomCore

/// The card behind the icon well: two tabs, a search field, and a hundred and fifty marks.
///
/// **Drawn inside the panel rather than in a `.popover` of its own, and that is a deliberate
/// refusal.** The form is already inside the composer's popover, and a popover opened from within
/// a popover is a second window: AppKit closes a transient popover the moment a click lands in a
/// window that is not it, so the first click on an emoji would take the form, the half written
/// prompt and the picker with it. The old inline grid's own comment named that argument as the
/// reason it had no well at all. The well is worth having, so what changed is where the card is
/// drawn, not whether the risk was real.
///
/// It is `MenuPanel`, which is the same card the composer's completion menus float in, opened into
/// a gap `QuickPromptForm` makes under the well. It used to be drawn over the form, and the owner
/// reported it as a panel that had escaped: it covered the Text field and the Save button, and its
/// left edge ran into the panel's own rounded corner. A card hung in room made for it covers
/// nothing, so all the shadow and the border are left to say is that it floats.
///
/// **Nothing in the grid is lazy, and that is the bug this file was opened for.** See
/// `QuickPromptMarkSection.rows(across:)`.
struct QuickPromptMarkPicker: View {
    /// The mark the prompt carries now, so the picker opens on it rather than at the top.
    var selection: String
    var onChoose: @MainActor (QuickPromptMark) -> Void
    var onClose: @MainActor () -> Void

    /// Which tab is open. It starts on the one holding the mark the prompt already carries, so
    /// somebody editing a prompt marked with an emoji is not shown a hundred symbols first.
    @State private var kind: QuickPromptMarkKind
    @State private var query = ""
    /// Where Return would go. Held as the mark itself and never as an index, for the reason
    /// `QuickPromptMenu.selected` writes down: a filtered list renumbers under every keystroke.
    @State private var highlighted: QuickPromptMark?

    /// **Both are settled here rather than in an `onAppear`, which is where they were.**
    ///
    /// `kind` defaulted to `.icons` and was corrected once the card had appeared, so the first pass
    /// of every open built the scroll view against nine bands of symbols and then replaced the
    /// whole of its content. Instrumented, that is exactly what it did: opening the picker on a
    /// prompt marked with a rocket printed `kind=icons bands=9` and then `kind=emoji bands=1`, one
    /// frame apart, every time. A scroll view whose content is swapped out from under it the frame
    /// after it is created is the one event that happens once per open, and the owner's report was
    /// about a first open. A `@State` given its value in `init` never has that frame.
    init(
        selection: String,
        onChoose: @escaping @MainActor (QuickPromptMark) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.selection = selection
        self.onChoose = onChoose
        self.onClose = onClose

        let current = QuickPromptMark(stored: selection)
        let tab = QuickPromptMarkCatalog.kind(of: current)
        _kind = State(initialValue: tab)
        _highlighted = State(
            initialValue: QuickPromptMarkCatalog.settled(
                QuickPromptMarkCatalog.sections(tab), after: current
            )
        )
    }

    /// Seven to a row. Wider rows put the marks further apart than the eye can take in at once,
    /// and narrower ones turn nine bands into a very long scroll. It was eight, at a cell smaller
    /// than the glyph in it wanted; a column came off rather than the card growing, because the
    /// card now sits inside the form's own width and has nowhere to grow into.
    static let columns = 7
    /// A cell, and the hit target with it. Larger than `Metrics.barHeight`, which is the smallest
    /// square this app asks anybody to click, because the owner read the grid as cramped: at 32
    /// around a 17 point mark there were seven points of air, and an emoji fills its em box where a
    /// symbol does not, so the rows read as touching even where the numbers said they were not.
    private static let cell: CGFloat = 36
    private static let inset: CGFloat = Metrics.spacingWide
    /// The point size a mark is drawn at inside its cell. See `QuickPromptMarkView`.
    private static let markPoints: CGFloat = 18

    static let width = CGFloat(columns) * cell + inset * 2
    /// Five rows of cells, and the padding around them.
    ///
    /// Five rather than the seven it was. The card hangs in a gap the form opens for it, so every
    /// row of it is a row the panel grows by, and a popover that grows by three hundred points to
    /// show a grid has taken over the window. Both tabs scroll at five, which is the other half of
    /// it: a band cut off part way down is what tells a reader there is more.
    private static let gridHeight: CGFloat = 5 * cell + Metrics.spacingWide * 2

    private var sections: [QuickPromptMarkSection] {
        QuickPromptMarkCatalog.filtered(kind, query: query)
    }

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                tabs
                searchRow
            }
            .padding(Self.inset)

            // The two controls are fixed and the grid under them moves, and without a line between
            // them a band heading scrolled half under the field read as a heading that had been
            // cut off rather than as one on its way past. The header block's own padding was not
            // enough to say which of the two it was.
            Hairline()

            grid(sections)
        }
        .frame(width: Self.width)
        .onChange(of: query) { _, _ in
            highlighted = QuickPromptMarkCatalog.settled(self.sections, after: highlighted)
        }
    }

    /// Icons or emoji, as a pill on a sunken track.
    ///
    /// Not `.pickerStyle(.segmented)`, which is a form control and read as one: a bordered slab
    /// across the top of a card that is otherwise a menu. It was two bare words before this, and
    /// the owner read the strip they sat on as an unfinished grey band, because the card's own
    /// padding was all that separated them from the field under them.
    ///
    /// **Local, and it should not stay that way.** `PanelTabs` in `Design/` is this control,
    /// written for the create sheet's two tabs, and its own note names this picker as the second
    /// caller. It was not on `main` when this was written. The colours and the two states here are
    /// its, so adopting it is a deletion rather than a redesign.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(QuickPromptMarkKind.allCases) { tab in
                tabCell(tab)
            }
        }
        .padding(Metrics.spacingTight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .fill(Palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What to mark this prompt with")
    }

    private func tabCell(_ tab: QuickPromptMarkKind) -> some View {
        let isSelected = kind == tab
        return Button {
            choose(tab: tab)
        } label: {
            Text(tab.title)
                // The weight carries the choice as well as the fill does, which is what keeps the
                // strip readable for somebody who cannot separate two greys.
                .font(isSelected ? Typo.labelEmphasis : Typo.label)
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.spacingSmall)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                            .fill(Palette.selected)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Switching tabs clears the query with it. The field belongs to the tab under it, and a query
    /// carried across meant landing in Emojis with "hammer" still in the box and nothing to show
    /// for it.
    private func choose(tab: QuickPromptMarkKind) {
        guard kind != tab else { return }
        kind = tab
        query = ""
        highlighted = QuickPromptMarkCatalog.sections(tab).first?.choices.first?.mark
    }

    /// The field, on a plate of its own.
    ///
    /// The plate is the whole change. An `NSTextField` with no border and no background, sat under
    /// a magnifying glass on the card's own ground, had an edge nowhere, and the owner read it as a
    /// caption rather than as somewhere to type. This is the box `QuickPromptForm` draws round its
    /// own text editor, out of the same two values and for the same reason.
    private var searchRow: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)

            MenuSearchField(
                text: $query,
                placeholder: kind == .icons ? "Search icons" : "Search emoji",
                onKey: handle(key:),
                onHorizontal: handle(horizontal:)
            )
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: Metrics.rowHeight)
        .background(
            Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
    }

    @ViewBuilder
    private func grid(_ sections: [QuickPromptMarkSection]) -> some View {
        if sections.isEmpty {
            MenuEmptyRow(text: "Nothing matches \(query)")
                .frame(height: Self.gridHeight, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.gutter) {
                        ForEach(sections) { section in
                            band(section)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, Self.inset)
                }
                .frame(height: Self.gridHeight)
                .onChange(of: highlighted) { _, mark in
                    guard let mark else { return }
                    proxy.scrollTo(mark.stored)
                }
                .onAppear {
                    guard let mark = highlighted else { return }
                    proxy.scrollTo(mark.stored, anchor: .center)
                }
            }
            // A tab change builds a new scroll view rather than swapping the content of the one
            // that is up. Nothing then has to reason about an offset, a measured height or a row
            // belonging to the other tab, because none of them survives the change.
            .id(kind)
        }
    }

    private func band(_ section: QuickPromptMarkSection) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            if let name = section.name {
                Text(name)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.rows(across: Self.columns)) { row in
                    HStack(spacing: 0) {
                        ForEach(row.choices) { choice in
                            cell(choice)
                        }
                    }
                }
            }
        }
    }

    /// One mark, in two states that used to look alike.
    ///
    /// **The mark the prompt carries is the loud one and the keyboard is the quiet one**, and it
    /// was the other way round. A teal ring on one cell and a teal fill on another were on screen
    /// at once, and a reader could not say which was which. Only one of the two is a fact about the
    /// prompt; the other is where Return would go, and it moves under every arrow press and every
    /// twitch of the pointer. So the fact wears the accent fill this app paints a chosen thing in
    /// everywhere else, and the transient one wears `Palette.hover`, the wash a row gets under the
    /// pointer, which says nothing louder than "here".
    private func cell(_ choice: QuickPromptMarkChoice) -> some View {
        let isChosen = choice.mark == QuickPromptMark(stored: selection)
        let isHighlighted = choice.mark == highlighted
        return Button {
            onChoose(choice.mark)
        } label: {
            QuickPromptMarkView(
                stored: choice.mark.stored,
                points: Self.markPoints,
                tint: isChosen ? Palette.selectedEmphasizedText : Palette.textSecondary
            )
            .frame(width: Self.cell, height: Self.cell)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(fill(chosen: isChosen, highlighted: isHighlighted))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(choice.mark.stored)
        .onHover { if $0 { highlighted = choice.mark } }
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func fill(chosen: Bool, highlighted: Bool) -> Color {
        if chosen { return Palette.selectedEmphasized }
        return highlighted ? Palette.hover : Color.clear
    }

    // MARK: - Keys

    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .up:
            highlighted = QuickPromptMarkCatalog.stepped(
                sections, from: highlighted, by: -Self.columns
            )
            return true
        case .down:
            highlighted = QuickPromptMarkCatalog.stepped(
                sections, from: highlighted, by: Self.columns
            )
            return true
        case .returnKey, .commandReturn:
            guard let highlighted else { return false }
            onChoose(highlighted)
            return true
        case .escape:
            // Closes the picker and nothing else. The form's own Escape is still behind this one,
            // and reaching it takes a second press, which is the right number: the first press
            // undoes the thing that was opened last.
            onClose()
            return true
        case .tab:
            // The one other thing this card can do, and the field under the tabs is where a hand
            // already is. Tab moves nothing else here: the card holds one field and a grid.
            choose(tab: kind == .icons ? .emoji : .icons)
            return true
        }
    }

    /// Left and right, and only while nothing has been typed.
    ///
    /// A grid wants four directions, and a field with a query in it wants its caret. Both are
    /// right, so the answer is which of them is on screen: an empty field has no text to move
    /// through, so the arrows are unambiguously the grid's; the moment there is a query there is
    /// something to edit, and the caret takes them back.
    private func handle(horizontal step: Int) -> Bool {
        guard query.isEmpty else { return false }
        highlighted = QuickPromptMarkCatalog.stepped(sections, from: highlighted, by: step)
        return true
    }
}
