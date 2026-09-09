import SwiftUI
import BloomCore

/// File sections share one vertical scroller. Each diff keeps its wrapped code,
/// comments and viewed control, and loads only as its section approaches the viewport.
struct AllFilesReviewView: View {
    let model: WorkspaceModel
    let selectedPath: String
    let navigationRevision: Int
    /// Keep the destination anchored while loading replaces short placeholders with full diffs.
    @State private var pendingDestination: String?
    @State private var layoutRevision = 0
    @State private var preparedPaths: Set<String> = []
    @State private var collapsedPaths: Set<String> = []
    @State private var hasNavigated = false

    var body: some View {
        if model.reviewFiles.isEmpty {
            EmptyStateView(
                glyph: "doc.text",
                title: "No changes",
                message: model.diffScope.emptyMessage(base: model.workspace.baseBranch)
            )
        } else {
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(model.reviewFiles) { file in
                                DiffView(
                                    model: model, file: file, embeddedWidth: geometry.size.width,
                                    embeddedViewportHeight: geometry.size.height,
                                    isCollapsed: collapsedPaths.contains(file.path),
                                    onScrollFocus: {
                                        if model.selectedFilePath != file.path { model.selectedFilePath = file.path }
                                    },
                                    onPrepared: {
                                        preparedPaths.insert(file.path)
                                        layoutRevision += 1
                                    },
                                    onToggleCollapsed: {
                                        pendingDestination = nil
                                        if !collapsedPaths.insert(file.path).inserted {
                                            collapsedPaths.remove(file.path)
                                        }
                                    }
                                )
                                .id(file.path)
                            }
                        }
                    }
                    .defaultScrollAnchor(.topLeading)
                    .onScrollPhaseChange { _, phase in
                        if phase == .tracking || phase == .interacting || phase == .decelerating {
                            pendingDestination = nil
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y <= geometry.contentInsets.top
                    } action: { _, atTop in
                        if atTop, let path = model.reviewFiles.first?.path,
                           model.selectedFilePath != path {
                            model.selectedFilePath = path
                        }
                    }
                    .onChange(of: navigationRevision, initial: true) { _, _ in
                        let requested = hasNavigated ? selectedPath : model.selectedFilePath ?? selectedPath
                        hasNavigated = true
                        let path = requested.isEmpty ? model.reviewFiles.first?.path : requested
                        guard let path, model.reviewFiles.contains(where: { $0.path == path }) else { return }
                        collapsedPaths.remove(path)
                        pendingDestination = preparedPaths.contains(path) ? nil : path
                        reader.scrollTo(path, anchor: .top)
                    }
                    .onChange(of: layoutRevision) { _, _ in
                        if let path = pendingDestination {
                            reader.scrollTo(path, anchor: .top)
                            if preparedPaths.contains(path) { pendingDestination = nil }
                        }
                    }
                    .onChange(of: model.reviewFiles.map(\.path)) { _, paths in
                        collapsedPaths.formIntersection(paths)
                        preparedPaths.formIntersection(paths)
                        if let pendingDestination, !paths.contains(pendingDestination) { self.pendingDestination = nil }
                    }
                }
            }
        }
    }
}
