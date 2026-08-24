import SwiftUI
import BloomCore

/// Where the work comes from: an open pull request, a branch somebody has already written on, or a
/// fresh branch cut off a base.
///
/// It replaces a `Menu` that listed "New branch from <name>" for every branch in the project and
/// filed "Open an existing branch" under all of them, with no way to search. A colleague's branch
/// was picked out of the top of that list, which cut a new branch off their head, and the
/// workspace came up empty with its Changes tab saying nothing differed. So the two verbs are
/// drawn as two sections, one above the other, with the same branch in both: the choice is made
/// with both answers in view rather than a screenful apart.
///
/// A `.popover` rather than a `Menu`, and not by preference. An `NSMenu` cannot contain a text
/// field, so a menu with a search box in it is not a thing macOS has; the panel is the app's own
/// filtered list instead, the one `FileMentionMenu` draws over the composer, with the same arrow
/// keys, the same Return and the same empty line when nothing matches.
struct WorkspaceSourcePicker: View {
    var offering: WorkspaceSourceOffering
    /// What is chosen now, which is what the button reports. Nil is the sheet's own route: a new
    /// branch off `baseBranch`.
    var checkout: WorkspaceCheckout?
    var baseBranch: String
    /// Why there are no pull requests, when there are none. Drawn at the foot of the panel rather
    /// than as a row, because "Sign in with gh" is not something to arrow onto and press Return on.
    var unavailable: String?
    var onPick: @MainActor (WorkspaceSource) -> Void

    @State private var isPresented = false
    @State private var query = ""
    /// The highlighted row, held as the row itself and never as an index into the list. A ranked
    /// list reorders under every keystroke, so an index highlights whatever has since moved into
    /// that slot and Return opens something other than what is drawn. `FileMentionMenu` carries
    /// the same note over the same failure.
    @State private var selected: WorkspaceSource?

    /// Wide enough for a pull request title beside its author without either being cut, which is
    /// what the old menu's 52 character truncation was working around.
    private static let width: CGFloat = 460
    /// Taller than `MenuLayout.maxHeight`, which is the cap a completion menu keeps because it
    /// floats over the composer it is filtering. This one hangs off a control at the top of a
    /// sheet with nothing underneath it worth reading, and it is a list people scan rather than a
    /// glance, so it gets about eleven rows instead of eight.
    private static let listHeight: CGFloat = 320

    private var matches: WorkspaceSourceMatches {
        offering.search(query: query)
    }

    private var label: String {
        WorkspaceSource.label(for: checkout, baseBranch: baseBranch)
    }

    /// The same three marks the rows carry, so the control shows the row that was picked. Cutting
    /// a new branch had the branch mark too, which left "from main" and "on main" telling the two
    /// apart on one word and no other difference at all.
    private var glyph: String {
        switch checkout {
        case .pullRequest: "arrow.triangle.pull"
        case .branch: "arrow.triangle.branch"
        case .none: "plus.circle"
        }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ComposerControlLabel(
                systemImage: glyph,
                text: label,
                isActive: isPresented,
                showsMenuIndicator: true
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Open a pull request or a branch, or cut a new branch")
        .accessibilityLabel("Start from")
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        // Ranked once for the whole pass, and everything below draws from that one value. The
        // panel asks three questions of it (is there anything, what goes in each section) and a
        // ranking run per question is the same list computed three times over a repository's worth
        // of branches, on every keystroke.
        let matches = self.matches
        return VStack(alignment: .leading, spacing: 0) {
            searchRow
            Hairline()

            if matches.isEmpty {
                MenuEmptyRow(
                    text: query.isEmpty
                        ? "No branches or pull requests yet"
                        : "Nothing matches \(query)"
                )
            } else {
                list(matches)
            }

            if let unavailable {
                Hairline()
                Text(unavailable)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.spacingWide)
            }
        }
        .frame(width: Self.width)
        // A fresh query every time it opens. The panel is a way of finding one thing, not a filter
        // somebody set and left, and reopening it onto yesterday's word would hide the list that
        // has since loaded behind it.
        .onAppear {
            query = ""
            selected = offering.search(query: "").ordered.first
        }
    }

    private var searchRow: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)

            MenuSearchField(
                text: $query,
                placeholder: "Search branches and pull requests, or paste a pull request",
                onKey: handle(key:)
            )
            .frame(height: Metrics.rowHeight)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingSmall)
        .onChange(of: query) { _, _ in
            // The highlight follows the list rather than staying where it was: a highlight left
            // pointing at a row the new query filtered out is a Return that does nothing.
            selected = matches.settled(after: selected)
        }
    }

    private func list(_ matches: WorkspaceSourceMatches) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The heading says what happens to the work that is already there, because
                    // "Open" alone reads as "open a copy of". Carrying on somebody's branch is
                    // what the sheet could not say before.
                    section("Open, and carry on", rows: matches.open)
                    section("New branch from", rows: matches.new)
                }
                .padding(Metrics.spacingSmall)
            }
            .frame(maxHeight: Self.listHeight)
            .onChange(of: selected) { _, row in
                guard let row else { return }
                proxy.scrollTo(row.id)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [WorkspaceSource]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Metrics.spacing)
                .padding(.top, Metrics.spacingWide)
                .padding(.bottom, Metrics.spacingTight)
                .accessibilityAddTraits(.isHeader)

            ForEach(rows) { row in
                WorkspaceSourceRow(
                    source: row,
                    isSelected: row == selected,
                    onPick: { pick(row) },
                    onHover: { selected = row }
                )
                // Identity is the thing the row names, never its position. See `selected`.
                .id(row.id)
            }
        }
    }

    // MARK: - Keys

    /// The panel's whole keyboard. Where the highlight lands is `WorkspaceSourceMatches`, in the
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
            guard let selected else { return false }
            pick(selected)
            return true
        case .escape:
            isPresented = false
            return true
        case .tab:
            return false
        }
    }

    private func pick(_ source: WorkspaceSource) {
        isPresented = false
        onPick(source)
    }
}
