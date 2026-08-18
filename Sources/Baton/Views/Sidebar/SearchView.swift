import SwiftUI
import BatonCore

/// The centre pane when the sidebar's Search row is selected.
///
/// The query lives on `AppModel` rather than here so that a search survives navigating away and
/// back, and so a menu command can put the user into search with a term already filled in.
struct SearchView: View {
    @Environment(AppModel.self) private var app

    @FocusState private var fieldFocused: Bool
    @State private var hovered: String?

    /// Matching runs when the query or the workspace list changes, not on every redraw. A search
    /// stays on screen while agents run, and each of them updates its diff stat every few seconds.
    @State private var hits: [AppModel.SearchHit] = []

    var body: some View {
        @Bindable var app = app

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            Hairline()

            results
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.windowBackground)
        .task { fieldFocused = true }
        .onChange(of: app.searchQuery, initial: true) { _, _ in match() }
        .onChange(of: app.workspaces) { _, _ in match() }
    }

    @ViewBuilder
    private var results: some View {
        if app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholder("Type to search", "Names, branches and project names are all matched.")
        } else if hits.isEmpty {
            placeholder("Nothing found", "No workspace matches \"\(app.searchQuery)\".")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
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
                .padding(10)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Typo.title)
                .foregroundStyle(Palette.textSecondary)
            Text(detail)
                .font(Typo.body)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    private func match() {
        hits = app.search(app.searchQuery)
    }

    private func clear() {
        app.searchQuery = ""
        fieldFocused = true
    }

    private func select(_ hit: AppModel.SearchHit) {
        app.selection = .workspace(hit.workspace.id)
    }
}
