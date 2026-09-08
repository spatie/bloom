import SwiftUI
import BloomCore

struct ServerReviewView: View {
    @Bindable var model: ServerReviewModel
    var server: ServerWindowModel?
    @State private var editing: ServerFileBuffer?
    @State private var previewsFile = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $model.showsAllFiles) {
                Text("Changes").tag(false)
                Text("Files").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: false, vertical: true).padding(12)
            if !model.showsAllFiles {
            Picker("Changes", selection: $model.scope) {
                Text("Branch").tag(ServerDiffScope.branch)
                Text("Uncommitted").tag(ServerDiffScope.uncommitted)
            }
            .pickerStyle(.segmented).labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            }
            if model.showsAllFiles {
                TextField("Filter files", text: $model.fileFilter).textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            }
            List(selection: $model.selectedPath) {
                if model.showsAllFiles {
                    ForEach(model.allFiles.filter { model.fileFilter.isEmpty || $0.localizedCaseInsensitiveContains(model.fileFilter) }, id: \.self) { path in
                        Label(path, systemImage: "doc").lineLimit(1).truncationMode(.middle).tag(path)
                    }
                } else {
                ForEach(model.files) { file in
                HStack {
                    Text(file.path).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if file.hasIncompleteStats {
                        Text("Large file").foregroundStyle(.secondary)
                    } else if file.isBinary {
                        Text("Binary").foregroundStyle(.secondary)
                    } else {
                        Text("+\(file.additions)").foregroundStyle(.green)
                        Text("-\(file.deletions)").foregroundStyle(.red)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .tag(file.path)
                .help(file.path)
                }
                }
            }
            .frame(minHeight: 100, idealHeight: 180, maxHeight: 240)
            Divider()
            if let path = model.selectedPath {
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Picker("View", selection: $model.showsFile) {
                        Text("Diff").tag(false)
                        Text("File").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: 120)
                    if server != nil {
                        Button("Preview", systemImage: "eye") { previewsFile.toggle() }.labelStyle(.iconOnly)
                    }
                    if model.showsFile, server != nil {
                        Button("Edit") { editing = server?.editBuffer() }
                            .disabled(model.fileRevision.isEmpty)
                    }
                }
                .padding(12)
                if previewsFile, let server, let workspaceID = server.selectedWorkspace?.id {
                    RemoteFilePreviewView(server: server, workspaceID: workspaceID, path: path)
                } else if let editing, editing.path == path, editing.workspaceID == server?.selectedWorkspace?.id, let server {
                    ServerFileEditorView(buffer: editing, server: server)
                } else if let error = model.error {
                    ContentUnavailableView("Cannot display this file", systemImage: "doc", description: Text(error))
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fileContents
                }
            } else if let error = model.error {
                ContentUnavailableView("Cannot load changes", systemImage: "doc", description: Text(error))
            } else {
                ContentUnavailableView(
                    model.files.isEmpty ? "No changes" : "Select a file", systemImage: "doc.text.magnifyingglass",
                    description: Text(model.files.isEmpty ? "Changes from the server will appear here." : "Review a diff or read the current file on the server.")
                )
            }
            if let server {
                Divider()
                ServerGitActionsView(model: server)
            }
        }
        .frame(minWidth: 330)
        .onChange(of: model.selectedPath) { _, _ in editing = nil; previewsFile = false }
        .onChange(of: model.showsAllFiles) { _, all in if all { model.showsFile = true } }
    }

    private var fileContents: some View {
        ScrollView([.horizontal, .vertical]) {
            if model.showsFile {
                Text(model.fileText).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else if model.lines.isEmpty {
                Text(model.patch.isEmpty ? "No text changes" : model.patch).padding(12)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.oldNumber.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                            Text(line.newNumber.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                            Text(marker(line.kind)).frame(width: 10)
                            Text(line.text.isEmpty ? " " : line.text)
                            Spacer(minLength: 12)
                        }
                        .padding(.vertical, 2)
                        .background(background(line.kind))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "-"
        case .context, .noNewline: " "
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.1)
        case .deletion: .red.opacity(0.1)
        case .context, .noNewline: .clear
        }
    }
}

private struct ServerFileEditorView: View {
    @Bindable var buffer: ServerFileBuffer
    var server: ServerWindowModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmsReload = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = buffer.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            SourceEditor(text: $buffer.text, language: .detect(path: buffer.path), colorScheme: colorScheme)
            HStack {
                Text(buffer.hasChanges ? "Unsaved changes" : "Saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload") {
                    if buffer.hasChanges { confirmsReload = true } else { Task { await server.reloadFile(buffer) } }
                }.disabled(buffer.isSaving)
                Button("Save") { Task { await server.saveFile(buffer) } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!buffer.hasChanges || buffer.isSaving)
            }
            .padding(10)
        }
        .confirmationDialog("Reload this file from the server? Your unsaved edits will be discarded.", isPresented: $confirmsReload) {
            Button("Reload", role: .destructive) { Task { await server.reloadFile(buffer) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
