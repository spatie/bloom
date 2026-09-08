import SwiftUI
import BloomCore

struct ServerReviewView: View {
    @Bindable var model: ServerReviewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Changes", selection: $model.scope) {
                Text("Branch").tag(ServerDiffScope.branch)
                Text("Uncommitted").tag(ServerDiffScope.uncommitted)
            }
            .pickerStyle(.segmented)
            .padding()
            List(model.files, selection: $model.selectedPath) { file in
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
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                .padding(12)
                if let error = model.error {
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
        }
        .frame(minWidth: 330)
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
