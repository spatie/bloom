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
/// a system service does and Bloom is not one. See `SearchPanelWindowOverlay` for the dimming, the
/// click outside and the placement.
struct SearchPanelView: View {
    var app: AppModel
    @Bindable var panel: SearchPanelModel

    /// How wide to draw, which is a fact about the window rather than about this view.
    ///
    /// It was a flat 560 here. `SearchPanelLayout.width(inWindow:)` is the decision now, in the
    /// core where it can be tested, and the overlay measures the window and hands the answer down.
    /// It is passed rather than measured here so that nothing about the query can move it: the
    /// card must not resize while somebody types, for the same reason the chips must not.
    var width: CGFloat

    /// Four rows and a bit, which is what a person reads before pressing Return. A taller list
    /// would be a pane, and a pane is Home.
    private static let listHeight: CGFloat = 310

    /// How much of the foot of the list is faded out, so a row at the edge reads as "there is more
    /// below" rather than as a row somebody has guillotined. See `fadeMask`.
    private static let fade: CGFloat = 28

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
                // `summary` is nil on an empty list of its own now. It used to count the two
                // fallback rows, so a card saying nothing matched carried "2 results" beside it.
                summary: panel.listing.summary
            )
        }
        .frame(width: width)
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

    /// The rows, or what the card says instead of them.
    ///
    /// **A fixed height, not a ceiling, and the owner chose it knowing what it costs.** It was
    /// `maxHeight`, so the card grew and shrank on the keystroke that changed how many results
    /// there were: twelve rows, then one, then none. Two separate reports on this branch were
    /// about the panel moving while somebody typed, and this is the same complaint one level up
    /// from the chips. Raycast holds a fixed panel for exactly this reason.
    ///
    /// The cost is a card taller than its content on a quiet machine, and taller still when it is
    /// empty: a fresh install opens this and gets three hundred points of card with one sentence
    /// in it. That was put to him with a picture of it and he kept it, because the alternative is
    /// a card that resizes under the pointer on nearly every keystroke. So it is a decision rather
    /// than an oversight, and it is not to be quietly tidied away by the next reader.
    @ViewBuilder
    private var list: some View {
        Group {
            if let nothing = panel.listing.nothing {
                SearchPanelNothingView(
                    nothing: nothing, isIndexing: app.isTranscriptIndexIncomplete
                )
            } else {
                rows
            }
        }
        .frame(height: Self.listHeight)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SearchPanelRowMetrics.gap) {
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
                                // More above than below, so a heading reads as belonging to what
                                // is under it. The rows around it breathe now, so the gap that
                                // used to say that at eight points has to say it at twelve.
                                .padding(.top, Metrics.gutter)
                                .padding(.bottom, Metrics.spacingTight)
                        }

                        ForEach(section.rows) { row in
                            self.row(row)
                                .id(row.id)
                        }
                    }
                }
                .padding(.top, Metrics.spacingSmall)
                // The fade below needs something to fade over, or it would eat the last row of a
                // list that fits. With this, a list short enough to fit ends above the fade and
                // nothing is faded at all; a long one scrolled to its end shows its last row
                // whole.
                .padding(.bottom, Self.fade)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask { fadeMask }
            // No anchor, so the arrows scroll the least they can get away with. Pinning would
            // throw the highlighted row to the far edge every time somebody stepped upwards, which
            // no Mac list does.
            .onChange(of: panel.highlighted) { _, index in
                guard let row = panel.listing.row(at: index) else { return }
                proxy.scrollTo(row.id)
            }
        }
    }

    /// The row at the bottom edge is faded out rather than sliced through.
    ///
    /// The list is a fixed height and the rows are not all one height, so no arithmetic makes the
    /// viewport land on a whole number of them: a heading, a one line command and a two line
    /// transcript hit are three different heights in the same list, and a height that fitted five
    /// workspaces would cut a transcript row instead. That is why the other answer, sizing the
    /// list to whole rows, is not available here. A fade also says something the cut does not:
    /// there is more below.
    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1 - Self.fade / Self.listHeight),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
        }
    }

    /// An action list is performed against the workspace that was pushed into rather than against
    /// whatever the Workspace menu is about, so the live menu's greying does not apply to it: the
    /// row is offered because `WorkspaceMenuSubject` allows it, which is the same rule Home's own
    /// menu for that workspace keeps.
    private func isRunnable(_ hit: SearchPanelCommandHit) -> Bool {
        panel.field.mode.workspaceID != nil || panel.runnable.contains(hit.item.action)
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
