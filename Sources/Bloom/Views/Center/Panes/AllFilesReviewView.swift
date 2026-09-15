import SwiftUI
import BloomCore

/// File sections share one vertical scroller. Each diff keeps its wrapped code,
/// comments and viewed control, and loads only as its section approaches the viewport.
struct AllFilesReviewView<Model: WorkspacePaneModel>: View {
    let model: Model
    let selectedPath: String
    let navigationRevision: Int
    /// A prepared file can still move when neighbouring diffs load or the lazy stack lays out.
    /// Hold the clicked destination until the reader scrolls or collapses a section.
    @State private var pendingDestination: String?
    @State private var layoutRevision = 0
    @State private var destinationPrepared = false
    @State private var collapsedPaths: Set<String> = []
    @State private var hasNavigated = false

    var body: some View {
        if model.reviewFiles.isEmpty {
            EmptyStateView(
                glyph: "doc.text",
                title: "No changes",
                message: model.diffScope.emptyMessage(base: model.workspace.baseBranch)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(model.reviewFiles) { file in
                                DiffView(
                                    model: model, file: file, embeddedWidth: geometry.size.width,
                                    embeddedViewportHeight: geometry.size.height,
                                    isCollapsed: collapsedPaths.contains(file.id),
                                    onScrollFocus: {
                                        guard hasNavigated, pendingDestination == nil else { return }
                                        if model.selectedFilePath != file.path {
                                            trace("scroll focus selected \(file.path)")
                                            model.selectedFilePath = file.path
                                        }
                                        if model.selectedChangeLayer != file.layer { model.selectedChangeLayer = file.layer }
                                    },
                                    navigationTarget: pendingDestination == file.id,
                                    onNavigationLayout: {
                                        guard pendingDestination == file.id else { return }
                                        scroll(to: file.id, using: reader, because: "destination moved")
                                    },
                                    onPrepared: {
                                        if pendingDestination == file.id { destinationPrepared = true }
                                        layoutRevision += 1
                                    },
                                    onToggleCollapsed: {
                                        trace("collapse of \(file.id) released \(pendingDestination ?? "nothing")")
                                        pendingDestination = nil
                                        if !collapsedPaths.insert(file.id).inserted {
                                            collapsedPaths.remove(file.id)
                                        }
                                    }
                                )
                                .id(file.id)
                            }
                        }
                        .background {
                            ReviewNavigationInput(armed: pendingDestination != nil) {
                                trace("input released \(pendingDestination ?? "nothing")")
                                pendingDestination = nil
                            }
                        }
                    }
                    .defaultScrollAnchor(.topLeading)
                    .onScrollPhaseChange { _, phase in
                        if phase == .tracking || phase == .interacting || phase == .decelerating {
                            if let pendingDestination { trace("scroll phase \(phase) released \(pendingDestination)") }
                            pendingDestination = nil
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y <= geometry.contentInsets.top
                    } action: { _, atTop in
                        if hasNavigated, pendingDestination == nil, atTop, let first = model.reviewFiles.first {
                            if model.selectedFilePath != first.path { model.selectedFilePath = first.path }
                            if model.selectedChangeLayer != first.layer { model.selectedChangeLayer = first.layer }
                        }
                    }
                    .onChange(of: navigationRevision, initial: true) { _, _ in
                        let requested = hasNavigated ? selectedPath : model.selectedFilePath ?? selectedPath
                        hasNavigated = true
                        let file = model.selectedChangedFile(path: requested) ?? model.reviewFiles.first
                        guard let file else { return }
                        let path = file.id
                        collapsedPaths.remove(path)
                        destinationPrepared = false
                        pendingDestination = path
                        model.selectedFilePath = file.path
                        model.selectedChangeLayer = file.layer
                        trace("navigate to \(path), revision \(navigationRevision), width \(Int(geometry.size.width))")
                        reader.scrollTo(path, anchor: .top)
                    }
                    .onScrollGeometryChange(for: CGSize.self) { geometry in
                        geometry.contentSize
                    } action: { _, size in
                        trace("content height \(Int(size.height))")
                        if let path = pendingDestination { scroll(to: path, using: reader, because: "content resized") }
                    }
                    .onChange(of: layoutRevision) { _, _ in
                        if let path = pendingDestination { scroll(to: path, using: reader, because: "a file was prepared") }
                    }
                    .onChange(of: model.reviewFiles.map(\.id)) { _, paths in
                        collapsedPaths.formIntersection(paths)
                        if let pendingDestination, !paths.contains(pendingDestination) {
                            trace("file list change released \(pendingDestination)")
                            self.pendingDestination = nil
                        }
                    }
                }
            }
        }
    }

    private func scroll(to path: String, using reader: ScrollViewProxy, because reason: String) {
        let relative = model.reviewFiles.first { $0.id == path }?.path ?? path
        let absolute = (model.workspace.path as NSString).appendingPathComponent(relative)
        if destinationPrepared, model.diffScope == .all, let destination = model.paneStores.sourceFile(absolute).diffRequest {
            trace("scroll to \(path) line \(destination.line), \(reason)")
            reader.scrollTo("\(path):definition:\(destination.line)", anchor: .center)
        } else {
            trace("scroll to \(path) top, \(reason)")
            reader.scrollTo(path, anchor: .top)
        }
    }

    /// Only the review probe records. The navigation probe has failed intermittently on CI with the
    /// scroller sitting on files six and seven after being asked for file three, and a list of the
    /// text views that happened to exist could not say whether a scroll was requested at all.
    private func trace(_ event: @autoclosure () -> String) {
        #if DEBUG
        if ReviewRunProbe.isRecording { ReviewRunProbe.trace(event()) }
        #endif
    }
}
