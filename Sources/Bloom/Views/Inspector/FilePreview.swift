import SwiftUI
import BloomCore

/// Reading and editing share the native text surface, including selection, find and navigation.
struct FilePreview: View {
    let model: WorkspaceModel
    let path: String
    var absolutePathOverride: String?
    var canEditInBloom = true
    @State private var width: CGFloat = 0
    private let session = FileEditSession.shared

    private var absolutePath: String {
        absolutePathOverride ?? (model.workspace.path as NSString).appendingPathComponent(path)
    }
    private var state: SourceEditorState { SourceEditorState.file(absolutePath) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: InspectorLayout.gap) {
                FilePathLabel(path: path, width: width)
                UnsavedEditsDot(session: session, path: absolutePath)
                Spacer(minLength: InspectorLayout.tight)
                Menu {
                    OpenInAppItems(target: .file(absolutePath))
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                } primaryAction: {
                    Reveal.inEditor(absolutePath, repo: model.repo?.id)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("Open in your editor")
                if canEditInBloom {
                    Picker("File view", selection: Binding(
                        get: { state.prefersEditing }, set: { state.prefersEditing = $0 }
                    )) {
                        Text("View").tag(false)
                        Text("Edit").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.barHeight)
            .background(Palette.surfaceSunken)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            Hairline()
            FileEditPane(model: model, path: path, session: session,
                         isEditable: canEditInBloom && state.prefersEditing, absolutePathOverride: absolutePathOverride)
        }
        .background(Palette.surface)
        .environment(\.openInRepoID, model.repo?.id)
        .onAppear { if session.isDirty(absolutePath) { state.prefersEditing = true } }
        .background {
            Button("Toggle View and Edit") { state.prefersEditing.toggle() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!canEditInBloom)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}
