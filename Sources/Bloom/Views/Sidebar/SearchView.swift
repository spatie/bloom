import SwiftUI
import BloomCore

/// The centre pane when the sidebar's Search row is selected.
///
/// The query lives on `AppModel` rather than here so that a search survives navigating away and
/// back, and so a menu command can put the user into search with a term already filled in.
struct SearchView: View {
    @Environment(AppModel.self) private var app

    @FocusState private var fieldFocused: Bool
    @State private var hovered: WorkspaceID?

    /// Matching runs when the query or the workspace list changes, not on every redraw. A search
    /// stays on screen while agents run, and each of them updates its diff stat every few seconds.
    @State private var hits: [AppModel.SearchHit] = []
    /// Archived workspaces, read once, for the same reason Home reads them: `AppModel` holds only
    /// active ones and this is a database read rather than a property.
    ///
    /// Search used to exclude them entirely, which is exactly backwards. Somebody who archived
    /// something and wants it back types its name in here first, and got "No Results" about a
    /// workspace whose branch was still on disk.
    @State private var archived: [Workspace] = []

    var body: some View {
        @Bindable var app = app

        return VStack(spacing: 0) {
            HStack(spacing: Metrics.spacingWide) {
                Image(systemName: "magnifyingglass")
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)

                TextField("Search workspaces, branches and projects", text: $app.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(Palette.textPrimary)
                    .focused($fieldFocused)

                if !app.searchQuery.isEmpty {
                    Button("Clear the search", systemImage: "xmark.circle.fill", action: clear)
                        .labelStyle(.iconOnly)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textTertiary)
                        .buttonStyle(.plain)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.inset)
            .frame(minHeight: Self.fieldHeight)
            .column()

            Hairline()

            results
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.windowBackground)
        .task { fieldFocused = true }
        .task(id: app.archivedRevision) {
            archived = await app.archivedWorkspaces()
            match()
        }
        .onChange(of: app.searchQuery, initial: true) { _, _ in match() }
        .onChange(of: app.workspaces) { _, _ in match() }
    }

    /// A search field is the one thing on this screen, so it is given the room a window's search
    /// field gets rather than the height of a list row. A minimum, not a fixed height, so it
    /// still fits its text at larger text sizes.
    private static let fieldHeight: CGFloat = 46
    /// A search result reads as a line, so the column is capped rather than run out to the width
    /// of the window. The field is capped to the same column: it used to run the full width of the
    /// pane, so the magnifying glass and the mark at the head of every result underneath it only
    /// shared a left edge at one particular window width.
    static let resultWidth: CGFloat = 760

    @ViewBuilder
    private var results: some View {
        if app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Type to search",
                systemImage: "magnifyingglass",
                description: Text("Names, branches and project names are all matched.")
            )
        } else if hits.isEmpty {
            ContentUnavailableView.search(text: app.searchQuery)
        } else {
            ScrollView {
                LazyVStack(spacing: Metrics.spacingTight) {
                    ForEach(hits) { hit in
                        SearchResultRow(
                            hit: hit,
                            isHovered: hovered == hit.id,
                            action: { select(hit) }
                        )
                        .onHoverChange { inside in
                            hovered = inside ? hit.id : (hovered == hit.id ? nil : hovered)
                        }
                    }
                }
                // Vertical only. A row carries its own horizontal inset, and adding a second one
                // here is what pushed every result a row's inset right of the field above them.
                .padding(.vertical, Metrics.inset)
                .column()
            }
        }
    }

    // MARK: - Actions

    private func match() {
        hits = app.search(app.searchQuery, alsoSearching: archived)
    }

    private func clear() {
        app.searchQuery = ""
        fieldFocused = true
    }

    /// An archived hit opens the reader rather than the centre column, which is the same split
    /// Home's rows make. See `ArchivedWorkspaceView`.
    private func select(_ hit: AppModel.SearchHit) {
        if hit.isArchived {
            app.openArchived(hit.workspace)
        } else {
            app.selection = .workspace(hit.workspace.id)
        }
    }
}

private extension View {
    /// The one column search is set in. The field and every result share it, so they line up at
    /// any window width rather than at one.
    func column() -> some View {
        frame(maxWidth: SearchView.resultWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
