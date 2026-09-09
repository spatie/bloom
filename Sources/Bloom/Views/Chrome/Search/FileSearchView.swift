import SwiftUI
import BloomCore

/// Cmd+P shares the window's search overlay and the composer's file rows.
struct FileSearchView: View {
    let app: AppModel
    let panel: SearchPanelModel
    @Bindable var model: FileSearchModel

    var body: some View {
        MenuPanel {
            HStack(spacing: Metrics.spacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textTertiary)
                MenuSearchField(
                    text: Binding(get: { model.query }, set: { model.type($0) }),
                    placeholder: "Search files…",
                    onKey: key(_:),
                    selectAllToken: panel.selectAllToken
                )
                .frame(height: Metrics.controlHeight)
                Text(model.workspace.name)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.spacingWide)
            Hairline()
            list.frame(height: 310)
            SearchPanelFooter(
                keys: [
                    .init(key: "↑↓", label: "Navigate"),
                    .init(key: "↩", label: "Open"),
                    .init(key: "esc", label: "Close"),
                ],
                summary: nil
            )
        }
        .task(id: model.query) { await model.search() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search Files")
    }

    @ViewBuilder private var list: some View {
        if model.isLoading {
            MenuEmptyRow(text: "Searching files…")
        } else if model.matches.isEmpty {
            MenuEmptyRow(text: model.query.isEmpty ? "No files in this workspace" : "No files match your search")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.matches.enumerated()), id: \.element.id) { index, match in
                            FileMentionRow(
                                match: match,
                                isSelected: model.highlighted == index,
                                onPick: { open(match) },
                                onHover: { model.highlighted = index }
                            )
                            .id(match.id)
                        }
                    }
                    .padding(Metrics.spacingSmall)
                }
                .onChange(of: model.highlighted) { _, _ in
                    if let selected = model.selected { proxy.scrollTo(selected.id) }
                }
            }
        }
    }

    private func open(_ match: FileMatch) {
        guard let workspace = app.workspaces.first(where: { $0.id == model.workspace.id }),
              !app.isArchiving(workspace.id) else {
            panel.close(app: app)
            return
        }
        panel.close(app: app)
        app.selection = .workspace(workspace.id)
        FileReview.open(path: match.path, in: app.model(for: workspace), focusing: true)
    }

    private func key(_ key: ComposerKey) -> Bool {
        switch key {
        case .up: model.move(.up)
        case .down: model.move(.down)
        case .returnKey, .commandReturn:
            if let match = model.selected { open(match) }
        case .escape: panel.close(app: app)
        case .tab: return false
        }
        return true
    }
}
