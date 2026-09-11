import SwiftUI
import BloomCore

/// File sections share one vertical scroller. Each diff keeps its wrapped code,
/// comments and viewed control, and loads only as its section approaches the viewport.
///
/// A jump to a file is not one `scrollTo`. The lazy stack places a file it has not drawn from
/// estimated heights, and diffs here run from a header to thousands of points, so a jump across
/// long files it had dropped landed wherever the estimate said: asked for the fifth of five long
/// files, it showed the end of the second, and asking again went back to the same place. So a jump
/// holds its destination until it arrives or the reader scrolls, and a landing in the wrong file
/// steps to that file's neighbour, whose position is exact because it touches something drawn.
struct AllFilesReviewView: View {
    let model: WorkspaceModel
    let selectedPath: String
    let navigationRevision: Int
    /// The file a jump is taking the reader to, until it arrives or they scroll for themselves.
    ///
    /// Not released when the destination has been laid out, which is what it used to do: files
    /// around it still load and grow afterwards, and one that grows above it pushes it down.
    @State private var pendingDestination: String?
    /// The file the last scroll of ours put at the top, which is the destination or a step on
    /// the way to it. A change in the stack's height anchors this again, rather than the
    /// destination, because asking for the destination from part way is asking the estimate.
    @State private var anchoredPath: String?
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
                                    onScrollFocus: { reached(file.path, reader: reader) },
                                    onToggleCollapsed: {
                                        release()
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
                    // Any scroll that is not the reader's stays idle: `scrollTo` here is not
                    // animated. So a wheel, a scroller drag or a keyboard page all let go of the
                    // jump, and a file finishing its layout later cannot drag the reader back.
                    .onScrollPhaseChange { _, phase in
                        if phase != .idle { release() }
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
                        pendingDestination = path
                        anchor(path, reader: reader)
                    }
                    // After layout, not when a file says it has been laid out. That report arrives
                    // before its new height is applied, so a scroll taken then measured the stack
                    // with the file still at its loading height, and the file grew over the
                    // destination anyway.
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                        if pendingDestination != nil, let anchoredPath {
                            reader.scrollTo(anchoredPath, anchor: .top)
                        }
                    }
                    .onChange(of: model.reviewFiles.map(\.path)) { _, paths in
                        collapsedPaths.formIntersection(paths)
                        if let pendingDestination, !paths.contains(pendingDestination) { release() }
                        if let anchoredPath, !paths.contains(anchoredPath) { self.anchoredPath = pendingDestination }
                    }
                }
            }
        }
    }

    /// A file's code reached the top. Selected when it is where the reader is, and otherwise a
    /// jump in progress that has landed short or long of its destination, which moves one file on.
    ///
    /// Only called when a file newly reaches the top, so a destination that cannot get there (a
    /// last file shorter than the pane) ends the walk on its neighbour rather than looping.
    private func reached(_ path: String, reader: ScrollViewProxy) {
        guard let destination = pendingDestination, destination != path else {
            if model.selectedFilePath != path { model.selectedFilePath = path }
            return
        }
        let files = model.reviewFiles
        guard let here = files.firstIndex(where: { $0.path == path }),
              let there = files.firstIndex(where: { $0.path == destination }) else { return }
        anchor(files[here < there ? here + 1 : here - 1].path, reader: reader)
    }

    private func anchor(_ path: String, reader: ScrollViewProxy) {
        anchoredPath = path
        reader.scrollTo(path, anchor: .top)
    }

    private func release() {
        pendingDestination = nil
        anchoredPath = nil
    }
}
