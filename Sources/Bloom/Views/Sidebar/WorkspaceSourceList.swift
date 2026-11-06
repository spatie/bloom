import SwiftUI
import BloomCore

/// The search field over one tab of ranked sources, with the panel's keyboard. Shared by the
/// create window's `WorkspaceSourcePicker` and the inspector's `TargetBranchPanel`, so choosing a
/// branch is one idiom in both.
struct WorkspaceSourceList: View {
    /// Ranked once by the panel for the whole pass. See `WorkspaceSourcePicker.panel`.
    var matches: WorkspaceSourceMatches
    var tab: WorkspaceSourceTab
    @Binding var query: String
    /// The highlighted row, held as the row itself and never as an index into the list. A ranked
    /// list reorders under every keystroke, so an index highlights whatever has since moved into
    /// that slot and Return opens something other than what is drawn. `FileMentionMenu` carries
    /// the same note over the same failure.
    @Binding var selected: WorkspaceSource?
    /// What the list says when it is empty before anything is typed.
    var emptyText: String
    /// What every row is, when it is not what its kind says. See `WorkspaceSourceRow.role`.
    var rowRole: WorkspaceSourceRow.Role?
    /// What the search field says, when the tab's own words are not this panel's.
    var placeholder: String?
    var onPick: @MainActor (WorkspaceSource) -> Void
    var onEscape: @MainActor () -> Void

    /// Taller than `MenuLayout.maxHeight`, which is the cap a completion menu keeps because it
    /// floats over the composer it is filtering. This one hangs off a control at the top of a
    /// sheet with nothing underneath it worth reading, and it is a list people scan rather than a
    /// glance, so it gets about eleven rows instead of eight.
    ///
    /// **A fixed height, never a `maxHeight`.** A popover sizes its content to its ideal size, and
    /// a `ScrollView` capped only from above has almost none, so the list opened a row and a half
    /// tall over a repository with dozens of branches. Fixed also means the panel keeps its size
    /// while the query narrows the list and when the tab changes, so the search field never moves
    /// under the pointer; the empty line sits in the same height for the same reason.
    private static let height: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Hairline()

            Group {
                if matches.isEmpty(in: tab) {
                    MenuEmptyRow(text: query.isEmpty ? emptyText : "Nothing matches \(query)")
                } else {
                    list
                }
            }
            .frame(height: Self.height, alignment: .top)
        }
    }

    private var searchRow: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)

            MenuSearchField(
                text: $query,
                placeholder: placeholder ?? tab.searchPlaceholder,
                onKey: handle(key:)
            )
            .frame(height: Metrics.rowHeight)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingSmall)
        .onChange(of: query) { _, _ in
            // The highlight follows the list rather than staying where it was: a highlight left
            // pointing at a row the new query filtered out is a Return that does nothing.
            selected = matches.settled(after: selected, in: tab)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.rows(in: tab)) { row in
                        WorkspaceSourceRow(
                            source: row,
                            isSelected: row == selected,
                            role: rowRole,
                            onPick: { onPick(row) },
                            onHover: { selected = row }
                        )
                        // Identity is the thing the row names, never its position. See `selected`.
                        .id(row.id)
                    }
                }
                .padding(Metrics.spacingSmall)
            }
            .onChange(of: selected) { _, row in
                guard let row else { return }
                proxy.scrollTo(row.id)
            }
        }
    }

    /// The list's whole keyboard. Where the highlight lands is `WorkspaceSourceMatches`, in the
    /// core, because it is a decision and a decision taken in a view is one nothing can test.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .up:
            selected = matches.stepped(from: selected, by: -1, in: tab)
            return true
        case .down:
            selected = matches.stepped(from: selected, by: 1, in: tab)
            return true
        case .returnKey, .commandReturn:
            guard let selected else { return false }
            onPick(selected)
            return true
        case .escape:
            onEscape()
            return true
        case .tab:
            return false
        }
    }
}
