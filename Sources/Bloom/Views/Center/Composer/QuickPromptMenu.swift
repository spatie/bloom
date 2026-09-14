import SwiftUI
import BloomCore

/// The panel behind the composer's quick prompt button: a search field, the prompts under it, and
/// one row at the foot to write a new one.
///
/// **Choosing a row puts its words in the box and stops**, unless that one prompt was written to
/// do more. Every one of these starts a turn against a real worktree, and a list somebody arrows
/// through by accident is the wrong place to be one keystroke away from that, so the two switches
/// on the form are off on every prompt until somebody turns them on. A prompt that has them on
/// says so on its own row, which is what makes arrowing past it safe: see `QuickPromptRow` for the
/// marks and `QuickPromptDelivery` for the four things a press can do.
///
/// A `.popover` rather than a `Menu`, for the reason `WorkspaceSourcePicker` writes down: an
/// `NSMenu` cannot contain a text field, so a menu with a search box in it is not a thing macOS
/// has. The panel is the app's own filtered list instead, with the same `MenuSearchField`, the same
/// arrow keys and the same empty line the composer's own menus use. It is not wrapped in
/// `MenuPanel`, which is the card the completion menus float in over the composer: a popover
/// already draws that card, and putting one inside the other is two borders and two shadows around
/// one list.
///
/// Number keys are not available and no shortcut hint pretends otherwise. The composer's text view
/// never resigns first responder while a menu is open, which `SlashCommandMenu` documents; this
/// panel takes the keyboard for its own field, so what is left is the arrows, Return and Escape.
///
/// **A project's own prompts come under the owner's**, beneath a Project heading, when the
/// repository's settings file offers any. With none the panel is drawn exactly as it was, heading
/// and all absent. The ranking, the empty states and what a project row does when chosen are all
/// `QuickPromptPanelMatches` and `QuickPromptPanelRow` in the core.
struct QuickPromptMenu: View {
    var catalog: QuickPromptCatalog
    /// What the workspace's repository offers, in file order. Empty wherever there is no
    /// workspace to read a settings file for.
    var projectPrompts: [ProjectQuickPrompt] = []
    @Binding var draft: QuickPromptFormDraft?
    /// What a chosen row does. The panel closes itself first, so the caret is put back in the
    /// composer rather than into a field that is about to go away.
    var onPick: @MainActor (QuickPromptPanelRow) -> Void
    var onClose: @MainActor () -> Void

    @Environment(AppModel.self) private var app

    @State private var query = ""
    /// The highlighted row, held as the row itself and never as an index into the list. A ranked
    /// list reorders under every keystroke, so an index highlights whatever has since moved into
    /// that slot and Return inserts something other than what is drawn. `WorkspaceSourcePicker`
    /// carries the same note over the same failure. Compared by `QuickPromptPanelRow.id`, which is
    /// what lets the highlight cross from the owner's section into the project's.
    @State private var selected: QuickPromptPanelRow?
    /// Hover for the row that writes a new prompt, which is not part of the ranked list and so has
    /// no `QuickPromptRow` to keep it.
    @State private var isNewHovered = false
    /// How tall the rows actually are, so the scroll view can be given a height rather than left
    /// to take whatever it is offered. See `rows(_:)`.
    @State private var contentHeight: CGFloat = 0
    /// The prompt Delete was pressed on, while the question about it is up.
    ///
    /// One piece of state for both routes into it, the pencil's form and the row's own context
    /// menu, because they ask the same question. See `QuickPromptDeletion`.
    @State private var deleting: QuickPrompt?

    /// Wide enough for a name and a line of the prompt under it without either being cut.
    /// Wider than the composer's other menus, because a row here carries a name somebody wrote
    /// rather than a file path, and at 320 the useful half of "Run the tests and fix whatever comes
    /// back failing" was behind an ellipsis.
    private static let width: CGFloat = 380

    /// How far the scrolling list holds its rows off the panel's edge.
    ///
    /// A selection drawn flush to the edge runs its rounded corners into the panel's own rounding
    /// and reads as a band painted across the popover rather than as a row picked out of a list.
    /// Every menu on this Mac insets it. Four points was not enough to see.
    private static let listInset: CGFloat = Metrics.spacingWide
    /// A row's own padding inside that.
    private static let rowInset: CGFloat = Metrics.spacing
    /// Where a glyph starts, measured from the panel's edge. Everything that is not a row of the
    /// list (the search field, the row that writes a new prompt) is indented to the same number,
    /// so the marks down the left are one column rather than three that nearly agree.
    private static var contentInset: CGFloat { listInset + rowInset }
    /// About eight rows, which is the cap a completion menu keeps in this app.
    private static let listHeight: CGFloat = 260

    private var matches: QuickPromptPanelMatches {
        QuickPromptPanelMatches.ranking(personal: catalog.prompts, project: projectPrompts, query: query)
    }

    var body: some View {
        Group {
            if draft != nil {
                form
            } else {
                list
            }
        }
        .frame(width: Self.width)
        .task { await catalog.load(from: app.store) }
        // A quick prompt is a paragraph the owner wrote and there is no undo for it. Delete used to
        // take the row on the click, from a list opened to pick something out of.
        .confirmation($deleting) {
            QuickPromptDeletion.confirmation(for: $0)
        } onConfirm: { prompt in
            delete(prompt)
            // The form was about the prompt that has just gone, so it goes with it. Cancelling
            // leaves it standing, which is the half that matters: nothing typed is lost by
            // pressing Delete and changing your mind.
            if draft?.editing?.id == prompt.id { draft = nil }
        }
    }

    // MARK: - The list

    private var list: some View {
        // Ranked once for the whole pass, and everything below draws from that one value: the
        // panel asks it three questions and a ranking per question is the same list computed three
        // times on every keystroke.
        let matches = self.matches
        return VStack(alignment: .leading, spacing: 0) {
            searchRow
            Hairline()

            if let notice = matches.notice(isLoaded: catalog.isLoaded) {
                empty(notice)
            } else {
                rows(matches)
            }

            Hairline()
            newRow
        }
        .onAppear {
            // A fresh query every time it opens. The panel is a way of finding one thing, not a
            // filter somebody set and left.
            query = ""
            selected = QuickPromptPanelMatches.ranking(
                personal: catalog.prompts, project: projectPrompts, query: ""
            ).rows.first
        }
        .onChange(of: catalog.prompts) { _, _ in
            selected = matches.settled(after: selected)
        }
        // The settings file is read again while the panel is up (it is asked to be when the panel
        // opens), so the highlight has to follow that list as well as the owner's.
        .onChange(of: projectPrompts) { _, _ in
            selected = matches.settled(after: selected)
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
                placeholder: "Search quick prompts",
                onKey: handle(key:)
            )
            .frame(height: Metrics.rowHeight)
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, Metrics.spacingSmall)
        .onChange(of: query) { _, _ in
            // The highlight follows the list rather than staying where it was: a highlight left
            // pointing at a row the new query filtered out is a Return that does nothing.
            selected = matches.settled(after: selected)
        }
    }

    /// The list, given an explicit height rather than a maximum one.
    ///
    /// **A `ScrollView` takes the height it is offered, not the height of what is in it.** Inside a
    /// popover that meant two different wrong answers on the same panel: on the first open, before
    /// the popover had settled on a size, the rows were laid out over the search field above them;
    /// on the second, one prompt sat at the top of three hundred points of empty panel.
    ///
    /// So the rows are measured and the scroll view is told what to be, clamped so a long list
    /// still scrolls instead of growing past the window. `LazyVStack` reports the height of what it
    /// has realised, which is why this is a plain `VStack`: the list is a handful of prompts
    /// somebody wrote by hand, and laziness here bought nothing and cost the measurement.
    private func rows(_ matches: QuickPromptPanelMatches) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.personal) { prompt in
                        row(.personal(prompt))
                    }

                    if matches.showsProjectHeading {
                        projectHeading(below: !matches.personal.isEmpty)
                        ForEach(matches.project) { prompt in
                            row(.project(prompt))
                        }
                    }
                }
                .padding(.horizontal, Self.listInset)
                .padding(.vertical, Metrics.spacingSmall)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: height(for: matches))
            .onChange(of: selected) { _, row in
                guard let row else { return }
                proxy.scrollTo(row.id)
            }
        }
    }

    private func row(_ row: QuickPromptPanelRow) -> some View {
        QuickPromptRow(
            row: row,
            isSelected: row.id == selected?.id,
            onPick: { pick(row) },
            onHover: { selected = row },
            onEdit: {
                guard case .personal(let prompt) = row else { return }
                draft = QuickPromptFormDraft(editing: prompt)
            },
            onDelete: {
                guard case .personal(let prompt) = row else { return }
                deleting = prompt
            },
            onCopy: {
                guard case .project(let prompt) = row else { return }
                copy(prompt)
            }
        )
        // Identity is the thing the row names, never its position. See `selected`.
        .id(row.id)
    }

    /// The line over the project's rows. Set the way the sidebar's section headers are, small and
    /// a step quieter than the names under it, so it reads as a label on a group rather than as a
    /// row that cannot be chosen. Indented to `rowInset` inside the list, which puts it in the same
    /// column as the marks.
    ///
    /// Air above it only when there is a section above it to be held apart from: with the owner's
    /// section empty it sits directly under the search field, where the list's own padding is
    /// already enough.
    private func projectHeading(below hasSectionAbove: Bool) -> some View {
        Text("Project")
            .font(Typo.captionEmphasis)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, Self.rowInset)
            .padding(.top, hasSectionAbove ? Metrics.spacing : Metrics.spacingTight)
            .padding(.bottom, Metrics.spacingTight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// Three different nothings. A list nobody has written to yet is worth a sentence saying what
    /// one of these is for, which is why it is not `MenuEmptyRow`: that draws a single quiet line,
    /// and a person who has never seen this panel needs the second one. Which of the three is
    /// `QuickPromptPanelNotice`, because a project's prompts made one of them wrong to show.
    @ViewBuilder
    private func empty(_ notice: QuickPromptPanelNotice) -> some View {
        switch notice {
        case .noMatches(let query):
            MenuEmptyRow(text: "Nothing matches \(query)", inset: Self.contentInset)
        case .loading:
            MenuEmptyRow(text: "Looking for quick prompts\u{2026}", inset: Self.contentInset)
        case .nothingYet:
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("Nothing here yet.")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Text("A quick prompt is a few lines you find yourself typing again.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.contentInset)
            .padding(.vertical, Metrics.gutter)
        }
    }

    /// The row that writes a new one. When something has been searched for and nothing matched, it
    /// offers to call the new prompt by it: somebody who searched for a prompt they have not
    /// written yet has just said what it should be called.
    private var newRow: some View {
        Button {
            draft = QuickPromptFormDraft(suggestedName: matches.isEmpty ? query : "")
        } label: {
            HStack(spacing: Metrics.gutter) {
                Image(systemName: "plus")
                    .imageScale(.medium)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)

                Text(newRowTitle)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.rowInset)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // It highlights under the pointer because it is a row of this menu, not a footnote under
        // one. Drawn flat, it was the one thing in the panel that did not answer to being hovered.
        .rowBackground(isSelected: false, isHovered: isNewHovered, isFocused: true)
        .onHover { isNewHovered = $0 }
        .padding(.horizontal, Self.listInset)
        .padding(.vertical, Metrics.spacingSmall)
    }

    /// What the scroll view is told to be.
    ///
    /// The measurement wins once there is one, and until then a guess from the row count stands in.
    /// Without the guess the first frame is one row tall, because `onGeometryChange` cannot report
    /// a height until after a layout has happened, and the panel visibly grew on opening. The guess
    /// only has to be close enough that nobody sees the correction.
    private func height(for matches: QuickPromptPanelMatches) -> CGFloat {
        let measured = contentHeight > 0
            ? contentHeight
            : Self.estimatedHeight(rows: matches.rows.count, heading: matches.showsProjectHeading)
        return min(max(measured, Metrics.rowHeight), Self.listHeight)
    }

    /// A two line row and the list's own padding, which is what a prompt with a name draws, and
    /// about a caption's line for the Project heading when there is one.
    private static func estimatedHeight(rows: Int, heading: Bool) -> CGFloat {
        CGFloat(rows) * (Metrics.rowHeight + Metrics.gutter) + Metrics.spacingWide
            + (heading ? Metrics.rowHeight - Metrics.spacingSmall : 0)
    }

    private var newRowTitle: String {
        guard matches.isEmpty, !query.isEmpty else { return "New quick prompt" }
        return "New quick prompt named \u{201C}\(query)\u{201D}"
    }

    // MARK: - The form

    private var form: some View {
        QuickPromptForm(
            draft: Binding(
                get: { draft ?? QuickPromptFormDraft() },
                set: { draft = $0 }
            ),
            onCancel: { draft = nil },
            onSave: { fields in save(draft?.editing, fields) },
            onDelete: {
                guard let editing = draft?.editing else { return }
                deleting = editing
            }
        )
    }

    // MARK: - Actions

    private func pick(_ row: QuickPromptPanelRow) {
        onClose()
        onPick(row)
    }

    /// Copy to My Quick Prompts: the project's words become a prompt of the owner's, which they
    /// can then edit and let send. The copy is highlighted when it lands, for the reason a newly
    /// written prompt is: it is the one somebody just asked for. It matches whatever the search
    /// says, because it has the same name and words as the row it was copied from.
    private func copy(_ prompt: ProjectQuickPrompt) {
        let catalog = catalog
        let store = app.store
        Task {
            let written = await catalog.add(prompt.personalFields, in: store)
            if let written { selected = .personal(written) }
        }
    }

    private func save(_ editing: QuickPrompt?, _ fields: QuickPrompt.Fields) {
        let catalog = catalog
        let store = app.store
        draft = nil
        Task {
            if let editing {
                await catalog.save(id: editing.id, fields, in: store)
            } else {
                let written = await catalog.add(fields, in: store)
                // The prompt somebody has just written is the one they were looking for, so the
                // list comes back with it highlighted and Return away from being used.
                if let written { selected = .personal(written) }
            }
        }
    }

    private func delete(_ prompt: QuickPrompt) {
        let catalog = catalog
        let store = app.store
        Task { await catalog.delete(id: prompt.id, in: store) }
    }

    // MARK: - Keys

    /// The panel's whole keyboard. Where the highlight lands is `QuickPromptPanelMatches`, in the
    /// core, because it is a decision and a decision taken in a view is one nothing can test.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .up:
            selected = matches.stepped(from: selected, by: -1)
            return true
        case .down:
            selected = matches.stepped(from: selected, by: 1)
            return true
        case .returnKey, .commandReturn:
            // Return on a search that matched nothing writes the prompt that is missing rather than
            // doing nothing at all.
            guard let selected else {
                guard !query.isEmpty else { return false }
                draft = QuickPromptFormDraft(suggestedName: query)
                return true
            }
            // The row as the list holds it now rather than as it was when it was highlighted, so a
            // settings file re-read in between cannot put yesterday's words in the box.
            pick(matches.rows.first { $0.id == selected.id } ?? selected)
            return true
        case .escape:
            onClose()
            return true
        case .tab:
            return false
        }
    }
}
