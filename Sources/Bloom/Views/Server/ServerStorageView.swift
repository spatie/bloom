import SwiftUI
import AppKit
import BloomCore
import BloomClient

struct ServerStorageView: View {
    let server: ServerWindowModel
    let showConnection: () -> Void
    @Bindable var model: ServerStorageModel
    @State private var review: ServerStorageModel.Review?
    @State private var confirmsCleanup = false

    private struct ConnectionState: Equatable {
        var generation: Int
        var connected: Bool
    }

    init(model: ServerStorageModel, showConnection: @escaping () -> Void) {
        self.server = model.server; self.showConnection = showConnection; self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text("Storage on " + server.displayName).font(Typo.heading)
                    Text("Review disk use and remove files Docker can recreate.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(!server.isConnected || model.isLoading || model.isCleaning)
            }.padding(Metrics.gutter)
            Form {
                if !server.isConnected {
                    Section {
                        Text("Connect to this server to inspect its storage and manage cleanup.")
                            .foregroundStyle(.secondary)
                        Button("Connection Settings", action: showConnection)
                    }
                } else if model.unsupported {
                    Section {
                        Label("Server update needed", systemImage: "arrow.down.circle")
                        Text("Update Bloom Server to use storage and cleanup tools. Existing workspaces are unaffected.")
                            .font(Typo.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if let report = model.report {
                        diskSection(report)
                        dockerSection(report)
                    }
                    if model.isLoading {
                        HStack(spacing: Metrics.spacing) {
                            ProgressView().controlSize(.small)
                            Text("Reading server storage…").foregroundStyle(.secondary)
                        }
                    }
                    if let result = model.lastCleanup { resultSection(result) }
                }
                if let error = model.error {
                    Section("Could not complete the request") {
                        Text(ServerSetupDiagnostics.sanitise(error)).textSelection(.enabled)
                            .font(Typo.caption).foregroundStyle(Palette.warning)
                        if model.needsRefresh {
                            Text("Cleanup may have changed some files. Refresh storage before trying again.")
                                .font(Typo.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
                }.disabled(model.report == nil && model.error == nil)
                Spacer()
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                    Text("Cleaning " + (model.cleaningServerName ?? server.displayName) + "…")
                        .font(Typo.caption).foregroundStyle(.secondary)
                } else if server.isPerformingCommand {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the current server action…").font(Typo.caption).foregroundStyle(.secondary)
                } else {
                    Button("Review Cleanup…") {
                        Task {
                            review = await model.prepareReview()
                            confirmsCleanup = review != nil
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                    .disabled(!model.canReview)
                }
            }.padding(Metrics.gutter)
        }
        .alert("Clean up Docker on \(review?.serverName ?? server.displayName)?", isPresented: $confirmsCleanup, presenting: review) { value in
            Button("Cancel", role: .cancel) {}
            Button("Clean Up", role: .destructive) {
                // An explicitly confirmed cleanup can finish after this settings window closes.
                Task { await model.clean(value) }
            }
        } message: { value in
            Text("Remove \(value.targets.map(\.title).joined(separator: " and ").lowercased()). Images used by containers, databases, uploads, workspace files and credentials will be kept. Future builds may need to download or rebuild files.")
        }
        .task(id: ConnectionState(generation: server.connectionGeneration, connected: server.isConnected)) {
            confirmsCleanup = false
            await model.refresh()
        }
    }

    private func diskSection(_ report: ServerStorageReport) -> some View {
        Section("Bloom data disk") {
            if let total = report.totalBytes, let free = report.freeBytes, total > 0 {
                let available = min(total, max(0, free))
                LabeledContent("Available", value: bytes(available) + " of " + bytes(total))
                ProgressView(value: Double(total - available), total: Double(total))
                    .tint(available < 2_147_483_648 ? Palette.warning : Palette.controlAccent)
                    .accessibilityLabel("Disk used")
                    .accessibilityValue(bytes(total - available) + " of " + bytes(total))
                if available < 2_147_483_648 {
                    Label("Disk space is running low", systemImage: "exclamationmark.triangle")
                        .font(Typo.caption).foregroundStyle(Palette.warning)
                }
            } else {
                Text("Disk capacity could not be measured.").foregroundStyle(.secondary)
            }
            Text("Checked " + report.checkedAt.formatted(date: .omitted, time: .shortened))
                .font(Typo.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func dockerSection(_ report: ServerStorageReport) -> some View {
        if !report.usage.isEmpty {
            Section("Docker usage") {
                ForEach(Array(report.usage.enumerated()), id: \.offset) { _, value in
                    LabeledContent {
                        Text(value.sizeLabel).monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                            Text(value.kind)
                            if let total = value.totalCount {
                                Text("\(total) total" + (value.activeCount.map { " · \($0) in use" } ?? ""))
                                    .font(Typo.caption).foregroundStyle(.secondary)
                            }
                            if let reclaimable = value.reclaimableLabel {
                                Text("Docker reports \(reclaimable) reclaimable")
                                    .font(Typo.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack(alignment: .top) {
                    Text("Images and build cache share layers. Their sizes cannot be added together.")
                    Spacer(minLength: Metrics.spacing)
                    Image(systemName: "questionmark.circle")
                        .help(report.notes.joined(separator: "\n\n"))
                        .accessibilityLabel("About Docker storage estimates")
                }.font(Typo.caption).foregroundStyle(.secondary)
            }
        }
        Section("Cleanup") {
            if report.dockerState == .ready {
                ForEach(ServerStorageCleanupTarget.allCases, id: \.self) { target in
                    Toggle(isOn: Binding(get: { model.selected.contains(target) }, set: { selected in
                        if selected { model.selected.insert(target) } else { model.selected.remove(target) }
                    })) {
                        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                            Text(target.title)
                            Text(target.detail).font(Typo.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(model.isLoading || model.isCleaning)
                }
            } else {
                Text(report.dockerMessage ?? "Docker cleanup is not available for this server account.")
                    .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        Section("Retained data") {
            Label("Databases and workspace data are kept", systemImage: "externaldrive.badge.checkmark")
            Text("This cleanup keeps database and Redis volumes, uploads, archived workspace data, credentials and swap. Archiving a workspace does not remove all of that data.")
                .font(Typo.caption).foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ result: ServerStorageCleanupResult) -> some View {
        Section(result.needsAttention ? "Cleanup needs attention" : "Cleanup finished") {
            ForEach(Array(result.outcomes.enumerated()), id: \.offset) { _, outcome in
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Label(outcome.target.title, systemImage: outcome.status == .completed ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(outcome.status == .completed ? Palette.controlAccent : Palette.warning)
                    Text(outcome.message).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let reclaimed = outcome.reclaimedLabel {
                        Text("Docker reported \(reclaimed) reclaimed").font(Typo.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if result.interrupted {
                Text("Cleanup stopped before every step was confirmed. Some data may already have been removed.")
                    .font(Typo.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
