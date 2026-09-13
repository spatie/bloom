import SwiftUI
import BloomClient

struct ServerSkillImportView: View {
    let model: ServerSkillsModel
    let session: ServerSkillsSession
    let prepared: () -> Void
    private let profile: String?
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var reference = ""

    init(model: ServerSkillsModel, session: ServerSkillsSession, prepared: @escaping () -> Void) {
        self.model = model; self.session = session; self.prepared = prepared
        profile = model.server.connectionProfile?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Add skills to " + model.server.displayName).font(Typo.heading)
            Text("Review a skill’s instructions and files before making it available to your agents.").settingsFootnote()
            GroupBox("From this Mac") {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("Choose a folder containing SKILL.md. Only that folder is considered; Bloom does not copy your agent settings or sign-ins.").settingsFootnote()
                    Button("Choose Skill Folder…") {
                        Task { if await model.importFolder() { dismiss(); prepared() } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(Metrics.spacing)
            }
            GroupBox("From Git") {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    TextField("Repository URL", text: $repository, prompt: Text("https://github.com/owner/skills"))
                    TextField("Branch, tag or commit", text: $reference, prompt: Text("Repository default"))
                    Text("The server uses its own GitHub access. You’ll review the exact commit and choose which skills to install.").settingsFootnote()
                    Button("Review Repository…") {
                        Task {
                            let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await session.previewGit(repositoryURL: repository.trimmingCharacters(in: .whitespacesAndNewlines), ref: ref.isEmpty ? nil : ref) {
                                guard model.session === session, model.server.connectionProfile?.id == profile else { return }
                                dismiss(); prepared()
                            }
                        }
                    }.disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.textFieldStyle(.roundedBorder).padding(Metrics.spacing)
            }
            if let error = model.localFailure ?? session.error {
                Text(error).foregroundStyle(Palette.warning).textSelection(.enabled)
            }
            HStack {
                if model.isReadingFolder || session.activity == .preparing { ProgressView("Preparing review…").controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 520)
        .disabled(model.isReadingFolder || session.activity != .idle)
        .interactiveDismissDisabled(model.isReadingFolder || session.activity != .idle)
    }
}
