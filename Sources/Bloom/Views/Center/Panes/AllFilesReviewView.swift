import SwiftUI
import BloomCore

/// File sections share one vertical scroller. Each diff keeps its horizontal scrolling,
/// comments and viewed control, and loads only as its section approaches the viewport.
struct AllFilesReviewView: View {
    let model: WorkspaceModel
    let selectedPath: String
    let navigationRevision: Int
    /// Keep the destination anchored while loading replaces short placeholders with full diffs.
    @State private var position = ScrollPosition(idType: String.self)
    @State private var collapsedPaths: Set<String> = []

    var body: some View {
        if model.changedFiles.isEmpty {
            EmptyStateView(
                glyph: "doc.text",
                title: "No changes",
                message: model.diffScope.emptyMessage(base: model.workspace.baseBranch)
            )
        } else {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    LazyVStack(spacing: Metrics.spacingWide) {
                        ForEach(model.changedFiles) { file in
                            DiffView(
                                model: model, file: file, embeddedWidth: geometry.size.width,
                                embeddedViewportHeight: geometry.size.height,
                                isCollapsed: collapsedPaths.contains(file.path),
                                onToggleCollapsed: {
                                    if !collapsedPaths.insert(file.path).inserted {
                                        collapsedPaths.remove(file.path)
                                    }
                                }
                            )
                                .overlay(alignment: .bottom) { Hairline() }
                                .id(file.path)
                        }
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.topLeading)
                .scrollPosition($position)
                .onChange(of: navigationRevision, initial: true) { _, _ in
                    let path = selectedPath.isEmpty ? model.changedFiles.first?.path : selectedPath
                    guard let path, model.changedFiles.contains(where: { $0.path == path }) else { return }
                    collapsedPaths.remove(path)
                    position.scrollTo(id: path, anchor: .top)
                }
                .onChange(of: model.changedFiles.map(\.path)) { _, paths in
                    collapsedPaths.formIntersection(paths)
                }
            }
        }
    }
}
