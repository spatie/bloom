import SwiftUI
import BloomClient

struct ServerSkillsView: View {
    @Bindable var model: ServerSkillsModel
    let showConnection: () -> Void
    @State private var showsImport = false
    @State private var selected: ServerSkill?
    @State private var reviewedPlan: ServerSkillsPlan?
    @State private var shouldReviewPreparedPlan = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Skills on this server") {
                    Text("Reusable instructions and supporting files for Claude and Codex. Skills stay on this server and can be managed from any connected client.").settingsFootnote()
                    if let workspace = model.projectScopeName {
                        Text("Includes project skills from " + workspace + ".").settingsFootnote()
                    } else {
                        Text("Server-wide skills. Select a workspace to include its project skills.").settingsFootnote()
                    }
                    if let workspace = model.server.selectedWorkspace, workspace.id != model.projectScope {
                        Button("Include project skills from " + workspace.name) { Task { await model.useCurrentWorkspace() } }
                            .disabled(!model.canUseCurrentWorkspace)
                    }
                    if !model.server.isConnected {
                        Text("Connect to see the server’s skills.").settingsFootnote()
                        HStack {
                            Button("Reconnect") { Task { await model.reconnect() } }.disabled(model.server.isMaintainingServer)
                            Button("Connection Settings", action: showConnection)
                        }
                    } else if let session = model.session {
                        if session.unsupported {
                            Text("Update Bloom Server to manage skills from this app.").settingsFootnote()
                        } else if session.skills.isEmpty, session.activity == .loading {
                            ProgressView("Reading skills…").controlSize(.small)
                        } else if session.skills.isEmpty, session.error == nil {
                            Text("No skills installed yet").font(Typo.labelEmphasis)
                            Text("Import a skill folder or review a Git repository to get started.").settingsFootnote()
                        } else {
                            ForEach(session.skills) { skill in skillRow(skill) }
                        }
                        ForEach(session.warnings, id: \.self) { Text($0).settingsFootnote().textSelection(.enabled) }
                    } else { ProgressView("Reading skills…").controlSize(.small) }
                }
                if let error = model.localFailure ?? model.session?.error {
                    Section("Skills need attention") {
                        Text(error).foregroundStyle(Palette.warning).textSelection(.enabled)
                        if let session = model.session, session.pendingMutationID != nil {
                            Text("The last request is unconfirmed. Retry it safely before making another change.").settingsFootnote()
                            Button("Retry Request") {
                                Task {
                                    if await session.retryPendingMutation(), let plan = session.plan { reviewedPlan = plan }
                                }
                            }.disabled(session.activity != .idle || !model.server.isConnected)
                        }
                    }
                }
            }.settingsForm()
            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(!model.server.isConnected || model.session?.activity != .idle || model.isReadingFolder)
                Spacer()
                if model.isReadingFolder { ProgressView("Reading selected folder…").controlSize(.small) }
                Button("Add Skills…") { showsImport = true }
                    .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                    .disabled(!model.server.isConnected || model.session?.canMutate != true || model.isReadingFolder)
            }.padding(Metrics.gutter)
        }
        .task(id: (model.server.connectionProfile?.id ?? "") + ":" + String(model.server.connectionGeneration) + ":" + String(model.server.isConnected)) {
            await model.refresh()
        }
        .onChange(of: model.server.connectionProfile?.id) {
            showsImport = false; selected = nil; reviewedPlan = nil; shouldReviewPreparedPlan = false
        }
        .sheet(isPresented: $showsImport, onDismiss: presentPreparedPlan) {
            if let session = model.session {
                ServerSkillImportView(model: model, session: session) { shouldReviewPreparedPlan = true }
            }
        }
        .sheet(item: $selected, onDismiss: presentPreparedPlan) { skill in
            if let session = model.session {
                ServerSkillDetailView(skill: skill, session: session) { shouldReviewPreparedPlan = true }
            }
        }
        .sheet(item: $reviewedPlan) { plan in
            if let session = model.session { ServerSkillPlanView(plan: plan, session: session) }
        }
    }

    private func skillRow(_ skill: ServerSkill) -> some View {
        Button { selected = skill } label: {
            HStack(alignment: .top, spacing: Metrics.spacing) {
                Image(systemName: skill.isManaged ? "doc.text" : "doc.text.magnifyingglass")
                    .foregroundStyle(Palette.textSecondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(Typo.labelEmphasis).foregroundStyle(Palette.textPrimary)
                    if !skill.description.isEmpty { Text(skill.description).font(Typo.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Text(Self.sourceTitle(skill.source) + " · " + (skill.enabledAgents.isEmpty ? "Disabled" : skill.enabledAgents.map { $0.rawValue.capitalized }.joined(separator: ", ")))
                        .font(Typo.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(Typo.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("Inspect instructions, source and agent access")
    }

    private func presentPreparedPlan() {
        guard shouldReviewPreparedPlan else { return }
        shouldReviewPreparedPlan = false
        reviewedPlan = model.session?.plan
    }

    static func sourceTitle(_ source: ServerSkillSource) -> String {
        switch source {
        case .personal: "Imported folder"
        case .git: "Git repository"
        case .project: "Project skill"
        case .unmanaged: "Managed outside Bloom"
        }
    }
}
