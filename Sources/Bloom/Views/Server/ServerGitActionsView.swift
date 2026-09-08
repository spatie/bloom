import SwiftUI
import BloomCore

struct ServerGitActionsView: View {
    @Bindable var model: ServerWindowModel
    @State private var form: FormKind?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isDraft = true
    @State private var result = ""

    private enum FormKind: String, Identifiable { case commit, pullRequest; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.isEmpty {
                if let url = URL(string: result), url.scheme == "https" { Link("Open pull request", destination: url) } else { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Commit…") { title = ""; form = .commit }
                Button("Push") { Task { await perform(.push) } }
                Spacer()
                Button("Create PR…") { title = model.selectedWorkspace?.name ?? ""; form = .pullRequest }
            }
            .controlSize(.small)
            .disabled(!model.isConnected || model.isPerformingCommand)
        }
        .padding(12)
        .sheet(item: $form) { kind in
            VStack(alignment: .leading, spacing: 16) {
                Text(kind == .commit ? "Commit all changes" : "Create pull request").font(.title3).fontWeight(.semibold)
                TextField(kind == .commit ? "Commit message" : "Title", text: $title)
                if kind == .pullRequest {
                    TextEditor(text: $bodyText).frame(height: 140)
                    Toggle("Draft pull request", isOn: $isDraft)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { form = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(kind == .commit ? "Commit" : "Create Pull Request") {
                        Task {
                            await perform(kind == .commit ? .commit(message: title) : .createPullRequest(title: title, body: bodyText, draft: isDraft))
                            if model.error == nil { form = nil }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(model.isPerformingCommand)
            }
            .padding(24).frame(width: 500)
            .interactiveDismissDisabled(model.isPerformingCommand)
        }
        .onChange(of: model.selectedWorkspace?.id) { _, _ in result = "" }
    }

    private func perform(_ action: ServerWorkspaceAction) async {
        if let reply = await model.workspaceAction(action), case .text(let text) = reply { result = text }
    }
}
