import SwiftUI
import BloomClient

struct ServerSkillDetailView: View {
    let skill: ServerSkill
    let session: ServerSkillsSession
    let reviewUpdate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agents: Set<ServerSkillAgent>
    @State private var confirmsAgents = false
    @State private var confirmsRemoval = false

    init(skill: ServerSkill, session: ServerSkillsSession, reviewUpdate: @escaping () -> Void) {
        self.skill = skill; self.session = session; self.reviewUpdate = reviewUpdate
        _agents = State(initialValue: Set(skill.enabledAgents))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(Typo.heading)
                    Text(skill.description).settingsFootnote()
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ServerSkillSourceView(skill: skill)
            HStack {
                ForEach(ServerSkillAgent.allCases, id: \.self) { agent in
                    Toggle(agent.rawValue.capitalized, isOn: Binding(get: { agents.contains(agent) }, set: {
                        if $0 { agents.insert(agent) } else { agents.remove(agent) }
                    }))
                }
                Spacer()
                if skill.isManaged {
                    Button(agents.isEmpty ? "Disable Skill…" : "Save Agent Access…") { confirmsAgents = true }
                        .disabled(!session.canMutate || agents == Set(skill.enabledAgents))
                }
            }.toggleStyle(.checkbox).disabled(!skill.isManaged)
            if !skill.isManaged {
                Text("This skill is managed by its project or another tool. Bloom can inspect it here.").settingsFootnote()
            }
            ServerSkillContentView(skill: skill, session: session)
            if let error = session.error { Text(error).foregroundStyle(Palette.warning).textSelection(.enabled) }
            HStack {
                if skill.isManaged {
                    Button("Remove Skill…", role: .destructive) { confirmsRemoval = true }.disabled(!session.canMutate)
                }
                Spacer()
                if skill.source == .git, let repository = skill.repositoryURL, let collection = skill.collectionID {
                    Button("Review Update…") {
                        Task {
                            if await session.previewGit(repositoryURL: repository, collectionID: collection) { dismiss(); reviewUpdate() }
                        }
                    }.disabled(!session.canMutate)
                }
            }
        }
        .padding(24).frame(width: 680, height: 650)
        .confirmationDialog(agents.isEmpty ? "Disable \(skill.name)?" : "Change agent access for \(skill.name)?",
                            isPresented: $confirmsAgents, titleVisibility: .visible) {
            Button(agents.isEmpty ? "Disable Skill" : "Save Agent Access") {
                Task {
                    if await session.setEnabled(skillID: skill.id, revision: skill.revision,
                                                agents: ServerSkillAgent.allCases.filter { agents.contains($0) }) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(agents.isEmpty ? "The managed files stay on the server, but neither agent will be offered this skill."
                 : "Make this skill available to " + ServerSkillAgent.allCases.filter { agents.contains($0) }.map { $0.rawValue.capitalized }.joined(separator: " and ") + ".")
        }
        .confirmationDialog("Remove \(skill.name) from the server?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Skill", role: .destructive) { Task { if await session.remove(skillID: skill.id, revision: skill.revision) { dismiss() } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Remove Bloom’s managed copy and stop making it available to agents. The original source is kept.") }
    }
}

struct ServerSkillSourceView: View {
    let skill: ServerSkill
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source: " + ServerSkillsView.sourceTitle(skill.source)).font(Typo.captionEmphasis)
            if let repository = skill.repositoryURL { Text(repository).textSelection(.enabled) }
            if let reference = skill.ref { Text("Reference: " + reference).textSelection(.enabled) }
            if let commit = skill.commit { Text("Commit: " + commit).textSelection(.enabled) }
            Text(skill.path).textSelection(.enabled)
            Text("\(skill.fileCount) files · " + ByteCountFormatter.string(fromByteCount: Int64(skill.byteCount), countStyle: .file))
            if let warning = skill.warning { Text(warning).foregroundStyle(Palette.warning).textSelection(.enabled) }
        }.font(Typo.caption).foregroundStyle(.secondary)
    }
}

struct ServerSkillContentView: View {
    let skill: ServerSkill
    let session: ServerSkillsSession
    var plan: ServerSkillsPlan?
    @State private var showsSource = false

    private var filePaths: [String] {
        if session.contentSkillID == skill.id, session.contentPlanID == plan?.id, let detail = session.detailSkill {
            return detail.filePaths
        }
        return skill.filePaths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("SKILL.md").font(Typo.captionEmphasis)
                Spacer()
                Toggle("Source", isOn: $showsSource).toggleStyle(.checkbox).font(Typo.caption)
            }
            ScrollView {
                if session.contentSkillID == skill.id, session.contentPlanID == plan?.id, let content = session.content {
                    if showsSource {
                        Text(content).font(Typo.codeSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else { MarkdownView(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                } else if let error = session.error { Text(error).settingsFootnote().textSelection(.enabled) } else {
                    ProgressView("Reading instructions…").controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            DisclosureGroup("Bundle files (\(filePaths.count))") {
                ScrollView {
                    Text(filePaths.joined(separator: "\n")).font(Typo.codeSmall).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 110)
            }.font(Typo.caption)
        }
        .task(id: skill.id + ":" + (plan?.id ?? "")) { await session.readDetails(skillID: skill.id, planID: plan?.id) }
    }
}
