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

                TextField("Search workspaces, branches and transcripts", text: $app.searchQuery)
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
                description: Text("Names, branches, projects, and everything the agents said.")
            )
        } else if hits.isEmpty && app.transcriptResults.isEmpty {
            ContentUnavailableView.search(text: app.searchQuery)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingTight) {
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

                    if !app.transcriptResults.isEmpty {
                        // A heading only over the second list. The first one needs none: what a
                        // workspace is called is what everybody assumes a search field searches,
                        // and labelling the obvious half made the screen read as a form.
                        Text("In transcripts")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, Metrics.inset)
                            .padding(.top, hits.isEmpty ? 0 : Metrics.inset)

                        // Keyed by the whole value, not by the workspace id, and that is the
                        // whole of the bug it fixes. Both lists are one `LazyVStack`, and a
                        // `SearchHit` is identified by its workspace id exactly as these are, so a
                        // workspace that matched by NAME and in its TRANSCRIPT was the same id
                        // twice in one lazy container and SwiftUI drew the first and dropped the
                        // second, leaving a gap. The workspace with the most matches is the one
                        // most likely to be in both lists, so the row being lost was reliably the
                        // best answer on the screen.
                        ForEach(app.transcriptResults, id: \.self) { result in
                            TranscriptResultRow(
                                result: result,
                                workspace: workspace(result.workspaceID),
                                repo: workspace(result.workspaceID).flatMap { app.repo(for: $0) },
                                isArchived: archived.contains { $0.id == result.workspaceID },
                                openWorkspace: { open(result) },
                                openMatch: { match in Task { await app.open(match) } }
                            )
                        }
                    }

                    if app.isTranscriptIndexIncomplete {
                        // Said out loud rather than hidden, because a search of a half built index
                        // is a search that can be wrong, and a wrong "No Results" about work the
                        // user knows they did is the one answer this screen must never give
                        // silently.
                        Label("Still indexing older transcripts", systemImage: "clock")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, Metrics.inset)
                            .padding(.top, Metrics.spacingWide)
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
        // The two halves are started together and answer separately. This one is an array already
        // in memory; the other is a hop onto the store actor, and making the names wait for the
        // transcripts would have put a database query in front of the answer that is nearly always
        // the one wanted.
        app.searchTranscripts(app.searchQuery)
    }

    private func workspace(_ id: WorkspaceID) -> Workspace? {
        app.workspaces.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    /// The whole workspace, from the header of a transcript result. Same split as a name hit: a
    /// live one opens the centre column, an archived one opens the reader.
    private func open(_ result: TranscriptWorkspaceMatches) {
        guard let workspace = workspace(result.workspaceID) else { return }
        if archived.contains(where: { $0.id == workspace.id }) {
            app.openArchived(workspace)
        } else {
            app.selection = .workspace(workspace.id)
        }
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
