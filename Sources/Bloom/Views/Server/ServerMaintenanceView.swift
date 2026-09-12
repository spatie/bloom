import SwiftUI
import AppKit
import BloomClient
import BloomAuthentication

struct ServerMaintenanceView: View {
    @Bindable var model: ServerMaintenanceModel
    let legacy: ServerToolUpdatesModel
    let showConnection: () -> Void
    let showAccounts: () -> Void
    @State private var showsAccess = false
    @State private var showsLegacy = false
    @State private var review: ServerMaintenancePlan?
    @State private var cancellation: ServerMaintenanceJob?

    var body: some View {
        Group {
            if showsLegacy, model.session?.unsupported == true {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to Updates") { showsLegacy = false }
                        Spacer()
                        Text("Legacy SSH updates").font(Typo.caption).foregroundStyle(.secondary)
                    }.padding(Metrics.gutter)
                    ServerToolUpdatesView(model: legacy, showConnection: showConnection, showAccounts: showAccounts)
                }
            } else {
                maintenanceContent
            }
        }
        .task(id: String(model.server.connectionGeneration) + String(model.server.isConnected)) { await model.observe() }
        .onChange(of: model.server.connectionGeneration) {
            review = nil; cancellation = nil; showsAccess = false; showsLegacy = false
        }
        .sheet(isPresented: $showsAccess) {
            if let access = model.access { ServerMaintenanceAccessView(access: access, serverName: model.server.displayName) }
        }
        .confirmationDialog("Update \(review?.component.title ?? "component") on \(model.server.displayName)?",
                            isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }),
                            titleVisibility: .visible, presenting: review) { plan in
            Button("Update") { start(plan, mode: .now) }.disabled(plan.isExpired() || model.session?.canStart != true)
            Button("Update When Idle") { start(plan, mode: .whenIdle) }.disabled(plan.isExpired() || model.session?.canStart != true)
            Button("Cancel", role: .cancel) { model.session?.discardPlan() }
        } message: { plan in
            Text(reviewSummary(plan))
        }
        .confirmationDialog("Cancel this update?",
                            isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }),
                            titleVisibility: .visible, presenting: cancellation) { job in
            Button("Cancel Update", role: .destructive) {
                guard let session = model.session, session.jobs.contains(where: { $0.id == job.id && $0.canCancel }) else { return }
                Task { await session.cancel(jobID: job.id) }
            }
            Button("Keep Update", role: .cancel) {}
        } message: { _ in
            Text("Bloom will cancel only if the update has not reached a step that must finish safely.")
        }
    }

    private var maintenanceContent: some View {
        VStack(spacing: 0) {
            Form {
                if !model.server.isConnected {
                    Section("Server updates") {
                        Text("Connect to check versions and manage updates.").settingsFootnote()
                        Button("Connection Settings", action: showConnection)
                    }
                } else if let session = model.session {
                    if session.unsupported {
                        Section("Managed updates aren’t available yet") {
                            Text("This server needs Bloom’s maintenance service before updates can continue independently of this app. Install it from server setup on your Mac.").settingsFootnote()
                            if legacy.connection != nil {
                                Button("Use Legacy SSH Updates…") { showsLegacy = true }
                                Text("Legacy updates manage AI tools over SSH. Keep the connection open until they finish.").settingsFootnote()
                            }
                        }
                    } else {
                        accessSection(session)
                        if !session.components.isEmpty { componentsSection(session) }
                        if session.isLoading { Section { ProgressView("Checking your server…").controlSize(.small) } }
                        if session.isPreparing { Section { ProgressView("Preparing update details…").controlSize(.small) } }
                        if let failure = session.failure, !failure.isAuthorizationFailure {
                            Section("Update needs attention") {
                                Text(failure.message).foregroundStyle(Palette.warning).textSelection(.enabled)
                                Text(failure.recovery).settingsFootnote().textSelection(.enabled)
                                if session.pendingMutationID != nil {
                                    Button("Retry Request") { Task { await session.retryPendingMutation() } }
                                        .disabled(session.isSubmitting)
                                }
                            }
                        }
                        if !session.jobs.isEmpty {
                            Section("Activity") {
                                ForEach(session.jobs) { job in jobRow(job, session: session) }
                            }
                        } else if session.authorized, !session.isLoading {
                            Section {
                                Text("Updates will appear here. You can close Bloom while an update runs and return to see its progress.").settingsFootnote()
                            }
                        }
                    }
                } else { Section { ProgressView("Checking your server…").controlSize(.small) } }
            }.settingsForm()
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.report, forType: .string)
                }.disabled(model.session == nil)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(!model.server.isConnected || model.session?.isLoading == true || model.session?.isSubmitting == true)
            }.padding(Metrics.gutter)
        }
    }

    private func accessSection(_ session: ServerMaintenanceSession) -> some View {
        Section("Maintenance access") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(session.authorized ? "This Mac can manage updates" : "Authorise this Mac to manage updates",
                          systemImage: session.authorized ? "checkmark.shield" : "lock.shield")
                    Text(session.authorized ? "Access is separate from your workspaces and agent sign-ins."
                         : "Use the maintenance key from server setup. It is saved only in this Mac’s Keychain.").settingsFootnote()
                }
                Spacer()
                Button(session.authorized ? "Manage…" : "Add Access…") { showsAccess = true }
                    .disabled(session.isSubmitting || model.access?.isPairing == true)
            }
            if let failure = model.access?.credentialFailure { Text(failure).foregroundStyle(Palette.warning).textSelection(.enabled) }
            if let failure = session.failure, failure.isAuthorizationFailure {
                Text(failure.message).settingsFootnote().textSelection(.enabled)
            }
        }
    }

    private func componentsSection(_ session: ServerMaintenanceSession) -> some View {
        Section("Components") {
            ForEach(session.components) { component in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(component.title).font(Typo.labelEmphasis)
                        Text("Installed: " + (component.installedVersion ?? "Not available"))
                            .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let available = component.availableVersion {
                            Text("Available: " + available).font(Typo.caption).textSelection(.enabled)
                        }
                        if !component.detail.isEmpty { Text(component.detail).settingsFootnote() }
                    }
                    Spacer()
                    if component.canUpdate {
                        Button("Review Update…") {
                            Task {
                                guard session.activity == .idle, session.pendingMutationID == nil else { return }
                                await session.prepare(component: component.id)
                                if model.session === session, session.plan?.component == component.id { review = session.plan }
                            }
                        }
                        .disabled(!session.authorized || session.activity != .idle || session.pendingMutationID != nil || session.jobs.contains(where: \.isActive))
                    }
                }
            }
        }
    }

    private func jobRow(_ job: ServerMaintenanceJob, session: ServerMaintenanceSession) -> some View {
        DisclosureGroup {
            if let message = job.message { Text(message).textSelection(.enabled) }
            if !job.logs.isEmpty {
                ScrollView {
                    Text(job.logs.map(\.message).joined(separator: "\n"))
                        .font(Typo.codeSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, idealHeight: 160, maxHeight: 220)
            }
            if job.canCancel {
                Button("Cancel Update…") { cancellation = job }.disabled(session.isSubmitting)
            }
        } label: {
            HStack(spacing: 10) {
                if job.isActive { ProgressView().controlSize(.small) } else {
                    Image(systemName: job.phase.needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(job.phase.needsAttention ? Palette.warning : Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.component.title + " " + job.targetVersion).font(Typo.label)
                    Text(job.phase.title + " · " + ServerMaintenancePresentation.date(job.updatedAt))
                        .font(Typo.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func start(_ plan: ServerMaintenancePlan, mode: ServerMaintenanceMode) {
        guard let session = model.session, session.plan?.id == plan.id, !plan.isExpired() else { return }
        Task { await session.start(mode: mode) }
    }

    private func reviewSummary(_ plan: ServerMaintenancePlan) -> String {
        let versions = (plan.fromVersion ?? "Not installed") + " → " + plan.targetVersion
        let restarts = plan.restarts.isEmpty ? "No services need to restart." : "Will restart: " + plan.restarts.joined(separator: ", ") + "."
        return [versions, plan.summary, restarts,
                "Update When Idle waits for running agents to finish. This plan expires " + ServerMaintenancePresentation.date(plan.expiresAt) + "."].joined(separator: "\n\n")
    }
}
