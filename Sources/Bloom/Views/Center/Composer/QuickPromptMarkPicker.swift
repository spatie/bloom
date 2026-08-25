import SwiftUI
import BloomCore

/// The card behind the icon well: a search field and a hundred and fifty marks in named bands.
///
/// **Drawn inside the panel rather than in a `.popover` of its own, and that is a deliberate
/// refusal.** The form is already inside the composer's popover, and a popover opened from within
/// a popover is a second window: AppKit closes a transient popover the moment a click lands in a
/// window that is not it, so the first click on an emoji would take the form, the half written
/// prompt and the picker with it. The old inline grid's own comment named that argument as the
/// reason it had no well at all. The well is worth having, so what changed is where the card is
/// drawn, not whether the risk was real.
///
/// It is `MenuPanel`, which is the same card the composer's completion menus float in, positioned
/// under the well by `QuickPromptForm`. Everything a popover would have given it, a shadow, a
/// border, the menu material and a click outside that dismisses it, it has; what it gives up is
/// being able to hang past the edge of the panel, which is why the form makes room underneath.
struct QuickPromptMarkPicker: View {
    /// The mark the prompt carries now, so the picker opens on it rather than at the top.
    var selection: String
    var onChoose: @MainActor (QuickPromptMark) -> Void
    var onClose: @MainActor () -> Void

    @State private var query = ""
    /// Where Return would go. Held as the mark itself and never as an index, for the reason
    /// `QuickPromptMenu.selected` writes down: a filtered list renumbers under every keystroke.
    @State private var highlighted: QuickPromptMark?

    /// Eight to a row. Wider rows put the marks further apart than the eye can take in at once,
    /// and narrower ones turn nine bands into a very long scroll.
    static let columns = 8
    /// A cell, and the hit target with it. Thirty two is the smallest square this app asks anybody
    /// to click at (`Metrics.barHeight`), and the mark inside it is set well under that.
    private static let cell: CGFloat = 32
    private static let inset: CGFloat = Metrics.spacingWide
    /// The point size a mark is drawn at inside its cell. See `QuickPromptMarkView`.
    private static let markPoints: CGFloat = 17

    static let width = CGFloat(columns) * cell + inset * 2
    /// About seven rows. Enough that a band and the start of the next one are visible together,
    /// which is what tells a reader that there is more under it.
    private static let gridHeight: CGFloat = 232
    /// What the whole card comes to, which `QuickPromptForm` has to make room for.
    static let height = gridHeight + Metrics.rowHeight + Metrics.spacingSmall * 2 + Metrics.hairline

    private var sections: [QuickPromptMarkSection] {
        QuickPromptMarkCatalog.filtered(query: query)
    }

    var body: some View {
        let sections = self.sections
        return MenuPanel {
            searchRow
            Hairline()
            grid(sections)
        }
        .frame(width: Self.width)
        .onAppear {
            highlighted = QuickPromptMarkCatalog.settled(
                QuickPromptMarkCatalog.sections, after: QuickPromptMark(stored: selection)
            )
        }
        .onChange(of: query) { _, _ in
            highlighted = QuickPromptMarkCatalog.settled(self.sections, after: highlighted)
        }
    }

    private var searchRow: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.repoIcon)

            MenuSearchField(
                text: $query,
                placeholder: "Search icons and emoji",
                onKey: handle(key:),
                onHorizontal: handle(horizontal:)
            )
            .frame(height: Metrics.rowHeight)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Metrics.spacingSmall)
    }

    @ViewBuilder
    private func grid(_ sections: [QuickPromptMarkSection]) -> some View {
        if sections.isEmpty {
            MenuEmptyRow(text: "Nothing matches \(query)")
                .frame(height: Self.gridHeight, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.spacingWide, pinnedViews: []) {
                        ForEach(sections) { section in
                            band(section)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, Metrics.spacingWide)
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
        }
    }

    private func band(_ section: QuickPromptMarkSection) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(section.name)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(Self.cell), spacing: 0), count: Self.columns
                ),
                spacing: 0
            ) {
                ForEach(section.choices) { choice in
                    cell(choice)
                }
            }
        }
    }

    private func cell(_ choice: QuickPromptMarkChoice) -> some View {
        let isHighlighted = choice.mark == highlighted
        let isCurrent = choice.mark == QuickPromptMark(stored: selection)
        return Button {
            onChoose(choice.mark)
        } label: {
            QuickPromptMarkView(
                stored: choice.mark.stored,
                points: Self.markPoints,
                tint: isHighlighted ? Palette.selectedEmphasizedText : Palette.textSecondary
            )
            .frame(width: Self.cell, height: Self.cell)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(isHighlighted ? Palette.selectedEmphasized : Color.clear)
            }
            // The mark the prompt already carries, when the keyboard is somewhere else. A ring
            // rather than a second fill: two filled cells read as two things chosen.
            .overlay {
                if isCurrent && !isHighlighted {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .strokeBorder(Palette.accent, lineWidth: Metrics.hairline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(choice.mark.stored)
        .onHover { if $0 { highlighted = choice.mark } }
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
            return false
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
