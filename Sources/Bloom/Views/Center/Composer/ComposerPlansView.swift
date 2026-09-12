import SwiftUI
import BloomCore

/// The saved revision is the handoff, so later refinements cannot rewrite an implementation's
/// source. Loading follows persisted transcript arrivals rather than individual streaming tokens.
struct ComposerPlansView: View {
    @Bindable var transcript: TranscriptModel
    var model: WorkspaceModel?
    var controls: ComposerControls
    @Environment(AppModel.self) private var app
    @State private var plans: [PlanArtefact] = []
    @State private var source: PlanArtefact?
    @State private var selectedID: PlanArtefactID?
    @State private var preview: PlanArtefact?
    @State private var isSubmitting = false

    private var selected: PlanArtefact? {
        plans.first { $0.id == selectedID } ?? plans.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            if let source {
                Button("From plan revision \(source.version)") { preview = source }
                    .buttonStyle(.plain)
                    .font(Typo.caption)
            }
            if let plan = selected {
                HStack(spacing: Metrics.spacing) {
                    Button { preview = plan } label: {
                        Text(plan.title).lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    Picker("Plan revision", selection: Binding(
                        get: { plan.id }, set: { selectedID = $0 }
                    )) {
                        ForEach(plans) { item in
                            Text("Revision \(item.version)").tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .font(Typo.label)

                if !transcript.isRunning && !transcript.isAwaitingPermission {
                    HStack(spacing: Metrics.spacing) {
                        Button("Refine") { refine() }
                            .disabled(!transcript.draft.contains { !$0.isWhitespace } || isSubmitting
                                || (transcript.session.agentKind == .codex && !ComposerPlanningSupport.shared.isAvailable))
                            .help("Send the draft as a refinement of this plan")
                        Button("Implement") { implement(plan, inNewConversation: false) }
                            .disabled(isSubmitting)
                        if model != nil {
                            Button("Implement in New Chat") { implement(plan, inNewConversation: true) }
                                .disabled(isSubmitting)
                        }
                    }
                    .font(Typo.label)
                }
            }
        }
        .padding(plans.isEmpty && source == nil ? 0 : Metrics.spacingSmall)
        .task(id: "\(transcript.session.id):\(transcript.rows.last?.seq ?? -1):\(transcript.isRunning):\(transcript.pendingDeliveries.last?.id.rawValue ?? "")") {
            await load()
        }
        .sheet(item: $preview) { plan in
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                HStack {
                    Text("Plan revision \(plan.version)").font(Typo.label)
                    Spacer()
                    if let model, model.sessions.contains(where: { $0.id == plan.sessionID }) {
                        Button("Open Source Chat") {
                            WorkspaceTabsStore.shared.reveal(.chat(plan.sessionID), in: model)
                            preview = nil
                        }
                    }
                    Button("Done") { preview = nil }.keyboardShortcut(.cancelAction)
                }
                ScrollView { MarkdownView(plan.markdown).frame(maxWidth: .infinity, alignment: .leading) }
                    .textSelection(.enabled)
            }
            .padding(Metrics.gutter)
            .frame(width: 640, height: 520)
        }
    }

    private func load() async {
        guard let store = app.store else { return }
        let sessionID = transcript.session.id
        do {
            let loaded = try await store.planArtefacts(sessionID: sessionID)
            let origin = try await store.sourcePlan(sessionID: sessionID)
            guard !Task.isCancelled, transcript.session.id == sessionID else { return }
            plans = loaded
            source = origin
        } catch {
            guard !Task.isCancelled else { return }
            app.notice = BloomNotice(message: "Could not load saved plans: \(error.localizedDescription)")
        }
    }

    private func refine() {
        guard let plan = selected else { return }
        let draft = transcript.draft
        guard draft.contains(where: { !$0.isWhitespace }) else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            if !InteractionMode.supports(transcript.session.agentKind) {
                await transcript.updatePreferences(permissionMode: .plan)
            }
            let text = "Refine this plan without implementing it:\n\n\(plan.markdown)\n\nRequested changes:\n\(draft)"
            _ = await transcript.submit(text, clearingDraft: draft, interactionMode: .plan)
        }
    }

    private func implement(_ plan: PlanArtefact, inNewConversation: Bool) {
        guard !isSubmitting, !transcript.isRunning, !transcript.isAwaitingPermission else { return }
        isSubmitting = true
        let origin = transcript
        var chosen = controls
        chosen.interactionMode = .build
        Task { @MainActor in
            defer { isSubmitting = false }
            guard let store = app.store else { return }
            // Claude's legacy Plan permission must become the user's chosen implementation
            // permission. Codex's independent permission value passes through unchanged.
            if chosen.permissionMode == .plan {
                chosen.permissionMode = (try? await store.planImplementationMode(
                    sessionID: origin.session.id, hasWorktree: origin.session.workspaceID != nil
                )) ?? .acceptEdits
            }
            let destination: TranscriptModel
            if inNewConversation {
                guard let model, let session = await model.createSession(
                    title: "Implement \(plan.title)", controls: chosen
                ) else {
                    app.notice = BloomNotice(message: "Could not create the implementation conversation.")
                    return
                }
                destination = model.transcript(for: session)
                await destination.load()
                WorkspaceTabsStore.shared.reveal(.chat(session.id), in: model)
            } else {
                destination = origin
            }
            await destination.updatePreferences(
                permissionMode: chosen.permissionMode, interactionMode: .build
            )
            guard await destination.submit(plan.implementationPrompt, interactionMode: .build, sourcePlan: plan) else { return }
            await load()
        }
    }
}
