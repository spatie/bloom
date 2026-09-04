import SwiftUI
import BloomCore

/// The card: a field, the chips, the list, and a strip of keys along the bottom.
///
/// **The same card the composer's two menus already sit in**, which is `MenuPanel`: one definition
/// of the glass, the rim, the corner and the shadow, so a third floating list cannot drift from the
/// two that were there first.
///
/// **Pinned near the top of the window rather than centred on the display.** The panel acts on this
/// window's contents, so it should visibly belong to this window; centring it on the screen is what
/// a system service does and Bloom is not one. See `SearchPanelOverlay` for the dimming and the
/// placement.
struct SearchPanelView: View {
    var app: AppModel
    @Bindable var panel: SearchPanelModel

    /// Wide enough for a workspace name, its project and an age on one line, and narrow enough that
    /// the eye does not have to travel to read a row. The composer's slash menu is 440 and holds a
    /// command name; this holds a sentence out of a transcript.
    static let width: CGFloat = 560

    /// Four rows and a bit, which is what a person reads before pressing Return. A taller list
    /// would be a pane, and a pane is Home.
    private static let listHeight: CGFloat = 310

    var body: some View {
        MenuPanel {
            field
            Hairline()

            if panel.field.mode.showsScopes, !panel.field.isEmpty {
                SearchPanelScopes(counts: panel.listing.counts, scope: scopeBinding)
                    .padding(.top, Metrics.spacingSmall)
            }

            list

            SearchPanelFooter(
                keys: SearchPanelKeys.footer(
                    for: panel.field.mode, isSearching: !panel.field.isEmpty
                ),
                summary: panel.listing.isEmpty ? nil : panel.listing.summary
            )
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Search")
    }

    // MARK: - The field

    /// The glyph, the mode's pill, the field itself, and what is being acted on.
    ///
    /// The pill is what tells you which mode you are in, and Backspace on an empty field is what
    /// takes it off again. That is GitHub's scope model rather than an invention: you narrow
    /// forwards and widen backwards.
    private var field: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textTertiary)

            if let pill = modePill {
                Chip(text: pill)
            }

            MenuSearchField(
                text: textBinding,
                placeholder: placeholder,
                onKey: key(_:),
                onBacktab: { handle(.backTab) },
                onDeleteEmpty: { handle(.backspaceOnEmpty) },
                onRight: { atEnd in
                    panel.caretAtEnd = atEnd
                    return handle(.right)
                },
                selectAllToken: panel.selectAllToken
            )
            .frame(height: Metrics.controlHeight)

            if let subject = commandSubject {
                Text("on \(subject)")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
    }

    /// The word in the pill. An action list names the workspace it is about, because "Action" on
    /// its own would be a label with nothing in it.
    private var modePill: String? {
        switch panel.field.mode {
        case .things: nil
        case .commands: SearchPanelMode.commands.pill
        case .actions: panel.drilledWorkspace(app: app)?.name ?? SearchPanelMode.actions(WorkspaceID("")).pill
        }
    }

    /// What the commands mode is aimed at, drawn on the trailing edge so a person can see which
    /// workspace Archive would take before they press it.
    private var commandSubject: String? {
        guard panel.field.mode == .commands else { return nil }
        return app.menuWorkspace?.name
    }

    private var placeholder: String {
        switch panel.field.mode {
        case .things: "Search workspaces, transcripts and commands"
        case .commands: "Run a command"
        case .actions: "Act on this workspace"
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let summary = panel.listing.summaryLine {
                        Text(summary)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, Metrics.inset)
                            .padding(.top, Metrics.spacingWide)
                            .padding(.bottom, Metrics.spacingSmall)
                    }

                    ForEach(panel.listing.sections) { section in
                        if let title = section.title {
                            // In the scroll rather than stuck to the top, because a sticky heading
                            // inside a list this tall eats one of the four rows you can see.
                            Text(title)
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                                .textCase(.uppercase)
                                .tracking(Typo.microTracking)
                                .padding(.horizontal, Metrics.inset)
                                .padding(.top, Metrics.spacingWide)
                                .padding(.bottom, Metrics.spacingTight)
                        }

                        ForEach(section.rows) { row in
                            self.row(row)
                                .id(row.id)
                        }
                    }

                    notice
                }
                .padding(.vertical, Metrics.spacingSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.listHeight)
            // No anchor, so the arrows scroll the least they can get away with. Pinning would
            // throw the highlighted row to the far edge every time somebody stepped upwards, which
            // no Mac list does.
            .onChange(of: panel.highlighted) { _, index in
                guard let row = panel.listing.row(at: index) else { return }
                proxy.scrollTo(row.id)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: SearchPanelRow) -> some View {
        let index = panel.listing.rows.firstIndex { $0.id == row.id }
        let isSelected = index != nil && index == panel.highlighted

        switch row {
        case .workspace(let hit):
            SearchPanelWorkspaceRow(
                hit: hit,
                isSelected: isSelected,
                onPick: { open(row) },
                onHover: { panel.highlighted = index }
            )

        case .transcript(let hit):
            SearchPanelTranscriptRow(
                hit: hit,
                isSelected: isSelected,
                onPick: { open(row) },
                onHover: { panel.highlighted = index }
            )

        case .command(let hit):
            SearchPanelCommandRow(
                hit: hit,
                isEnabled: isRunnable(hit),
                isSelected: isSelected,
                onPick: { open(row) },
                onHover: { panel.highlighted = index }
            )

        case .fallback(let fallback):
            SearchPanelFallbackRow(
                fallback: fallback,
                isSelected: isSelected,
                onPick: { open(row) },
                onHover: { panel.highlighted = index }
            )
        }
    }

    /// An action list is performed against the workspace that was pushed into rather than against
    /// whatever the Workspace menu is about, so the live menu's greying does not apply to it: the
    /// row is offered because `WorkspaceMenuSubject` allows it, which is the same rule Home's own
    /// menu for that workspace keeps.
    private func isRunnable(_ hit: SearchPanelCommandHit) -> Bool {
        panel.field.mode.workspaceID != nil || panel.runnable.contains(hit.item.action)
    }

    /// The two things drawn under the list, and neither of them is an error.
    ///
    /// A search here cannot fail in a way worth drawing: `TranscriptSearch.matchExpression` quotes
    /// every token before it reaches FTS5, so the store either answers or the task was cancelled by
    /// the next keystroke. What is left is the one honest condition, the index still being built,
    /// stated as a fact under the list rather than as a failure across it.
    @ViewBuilder
    private var notice: some View {
        if !panel.field.isEmpty, panel.field.mode == .things,
           let sentence = SearchPanelFallback.indexNotice(isIndexing: app.isTranscriptIndexIncomplete) {
            Label(sentence, systemImage: "clock")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Metrics.inset)
                .padding(.vertical, Metrics.spacingSmall)
        }
    }

    // MARK: - Bindings and keys

    private var textBinding: Binding<String> {
        Binding(
            get: { panel.field.text },
            set: { panel.type($0, app: app) }
        )
    }

    private var scopeBinding: Binding<HomeScope> {
        Binding(
            get: { panel.scope },
            set: { panel.setScope($0, app: app) }
        )
    }

    private func open(_ row: SearchPanelRow) {
        SearchPanelActivation.open(row, panel: panel, app: app)
    }

    /// The keys the field hands over, mapped onto the enum the core answers.
    private func key(_ key: ComposerKey) -> Bool {
        switch key {
        case .up: handle(.up)
        case .down: handle(.down)
        case .tab: handle(.tab)
        case .returnKey: handle(.returnKey)
        case .commandReturn: handle(.commandReturn)
        case .escape: handle(.escape)
        }
    }

    /// - Returns: whether the field should keep the key. False hands it back to the field editor,
    ///   which is what leaves Tab moving the focus in a mode that has no chips.
    private func handle(_ key: SearchPanelKey) -> Bool {
        switch SearchPanelKeys.outcome(for: key, in: panel.keyContext) {
        case .move(let index):
            panel.highlighted = index
            return true
        case .open:
            guard let row = panel.listing.row(at: panel.highlighted) else { return true }
            open(row)
            return true
        case .drill:
            return panel.drill(app: app)
        case .scope(let scope):
            panel.setScope(scope, app: app)
            return true
        case .leaveMode:
            return panel.leaveMode(app: app)
        case .clearQuery:
            panel.clearQuery(app: app)
            return true
        case .close:
            panel.close(app: app)
            return true
        case .handled:
            return true
        case .ignored:
            return false
        }
    }
}
