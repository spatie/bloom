import SwiftUI
import BloomCore

struct RemoteReviewPane: View {
    @Bindable var server: ServerWindowModel
    @State private var editing: ServerFileBuffer?
    @State private var didSave = false

    private var review: ServerReviewModel { server.review }

    var body: some View {
        VStack(spacing: 0) {
            if let path = review.selectedPath, let workspace = server.selectedWorkspace {
                HStack(spacing: InspectorLayout.gap) {
                    Text(path).font(Typo.codeSmall).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Preview", systemImage: "eye") { editing = nil; review.showsFile = true }
                    Button("Diff") { editing = nil; review.showsFile = false }
                    Button("Edit") { Task {
                        review.showsFile = true
                        let loaded = await server.loadEditBuffer(path: path, workspaceID: workspace.id)
                        guard server.selectedWorkspace?.id == workspace.id, review.selectedPath == path else { return }
                        editing = loaded
                    } }
                }
                .controlSize(.small).padding(.horizontal, InspectorLayout.inset)
                .frame(height: InspectorLayout.barHeight).background(Palette.surfaceSunken)
                Hairline()
                if let editing, editing.path == path, editing.workspaceID == workspace.id {
                    FileEditorSurface(text: Binding(get: { editing.text }, set: { editing.text = $0; didSave = false }), path: path,
                        status: editing.error.map(FileEditSession.Status.failed) ?? (didSave ? .saved : .idle),
                        hasContents: true, isDirty: editing.hasChanges, isSaving: editing.isSaving,
                        onSave: { Task { await server.saveFile(editing); didSave = editing.error == nil } },
                        onReload: { Task { await server.reloadFile(editing); didSave = false } })
                } else if review.showsFile {
                    RemoteFilePreviewView(server: server, workspaceID: workspace.id, path: path)
                } else if let error = review.error {
                    EmptyStateView(glyph: "doc", title: "Cannot display this file", message: error)
                } else if review.isLoading {
                    LoadingView("Reading the diff").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    diff(path: path)
                }
            } else {
                EmptyStateView(glyph: "doc.text", title: "Select a file", message: "Pick a file in the inspector to review it.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.surface)
        .onChange(of: review.selectedPath) { _, _ in editing = nil; didSave = false }
        .onChange(of: server.selectedWorkspace?.id) { _, _ in editing = nil; didSave = false }
        .task(id: (server.selectedWorkspace?.id.rawValue ?? "") + (review.selectedPath ?? "")) {
            if let workspace = server.selectedWorkspace, let path = review.selectedPath,
               let held = server.cachedEditBuffer(path: path, workspaceID: workspace.id), held.hasChanges { editing = held }
        }
    }

    private func diff(path: String) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, CGFloat(review.lines.map { CodeMetrics.columns(of: $0.text) }.max() ?? 0) * CodeMetrics.advance + 120)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stride(from: 0, to: review.lines.count, by: 128)), id: \.self) { start in
                        let lines = review.lines[start..<min(start + 128, review.lines.count)]
                        DiffRunView(lines: lines.map { DiffRunLine(line: $0) }, language: .detect(path: path), width: width)
                    }
                    if review.lines.isEmpty {
                        Text(review.patch.isEmpty ? "No text changes" : review.patch).font(Typo.code).padding(InspectorLayout.inset)
                    }
                }
            }
        }
    }
}
