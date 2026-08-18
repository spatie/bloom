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

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textTertiary)

                TextField("Search workspaces, branches and projects", text: $app.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(Palette.textPrimary)
                    .focused($fieldFocused)

                if !app.searchQuery.isEmpty {
                    Button {
                        app.searchQuery = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textTertiary)
                    }
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
    }

    @ViewBuilder
    private var results: some View {
        let hits = app.search(app.searchQuery)

        if app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholder("Type to search", "Names, branches and project names are all matched.")
        } else if hits.isEmpty {
            placeholder("Nothing found", "No workspace matches \"\(app.searchQuery)\".")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(hits) { hit in
                        row(hit)
                    }
                }
                .padding(10)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func row(_ hit: AppModel.SearchHit) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(hit.repo.map { Color(hexString: $0.accent) } ?? Palette.textTertiary)
                .frame(width: 9, height: 9)

            Text(hit.repo?.name ?? "Unknown project")
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)

            Text(hit.workspace.name)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Chip(text: hit.workspace.branch, systemImage: "arrow.triangle.branch", monospaced: true)

            if hit.workspace.hasDiff {
                DiffStatLabel(
                    additions: hit.workspace.additions,
                    deletions: hit.workspace.deletions,
                    compact: true
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .rowBackground(isSelected: false, isHovered: hovered == hit.id)
        .contentShape(Rectangle())
        .onHoverChange { inside in
            hovered = inside ? hit.id : (hovered == hit.id ? nil : hovered)
        }
        .onTapGesture { app.selection = .workspace(hit.workspace.id) }
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
}
