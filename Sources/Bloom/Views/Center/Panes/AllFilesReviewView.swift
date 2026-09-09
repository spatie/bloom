import SwiftUI
import BloomCore

/// File sections share one vertical scroller. Each diff keeps its wrapped code,
/// comments and viewed control, and loads only as its section approaches the viewport.
struct AllFilesReviewView: View {
    let model: WorkspaceModel
    let selectedPath: String
    let navigationRevision: Int
    /// Keep the destination anchored while loading replaces short placeholders with full diffs.
    @State private var position = ScrollPosition(idType: String.self)
    @State private var collapsedPaths: Set<String> = []
    @State private var hasNavigated = false

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
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.changedFiles) { file in
                            DiffView(
                                model: model, file: file, embeddedWidth: geometry.size.width,
                                embeddedViewportHeight: geometry.size.height,
                                isCollapsed: collapsedPaths.contains(file.path),
                                onScrollFocus: {
                                    if model.selectedFilePath != file.path { model.selectedFilePath = file.path }
                                },
                                onToggleCollapsed: {
                                    if !collapsedPaths.insert(file.path).inserted {
                                        collapsedPaths.remove(file.path)
                                    }
                                }
                            )
                        }
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.topLeading)
                .scrollPosition($position)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= geometry.contentInsets.top
                } action: { _, atTop in
                    if atTop, let path = model.changedFiles.first?.path,
                       model.selectedFilePath != path {
                        model.selectedFilePath = path
                    }
                }
                .onChange(of: navigationRevision, initial: true) { _, _ in
                    let requested = hasNavigated ? selectedPath : model.selectedFilePath ?? selectedPath
                    hasNavigated = true
                    let path = requested.isEmpty ? model.changedFiles.first?.path : requested
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
