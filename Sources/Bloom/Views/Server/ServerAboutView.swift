import SwiftUI
import BloomCore
import BloomClient

/// What this server is, what Bloom installed on it and what it cannot do, in a place that stays
/// true after setup has closed. Uninstalling starts here because this is where the installation
/// is described, so the reader sees what exists before choosing to remove it.
struct ServerAboutView: View {
    let server: ServerWindowModel
    let maintenance: ServerMaintenanceModel
    @Binding var uninstall: ServerSetupModel?
    let removeFromThisMac: () -> Void
    @State private var diagnostics: ServerDiagnostics?
    @State private var diagnosticsFailure: String?

    private var summary: ServerInstallationSummary {
        ServerInstallationSummary(connectionHost: server.host, executable: server.executable, dataDirectory: server.remoteDirectory)
    }

    private var installedVersion: String {
        if let version = maintenance.session?.components.first(where: { $0.id == .server })?.installedVersion { return version }
        return server.isConnected ? "Shown in Updates" : "Connect to see"
    }

    var body: some View {
        Form {
            Section("This server") {
                LabeledContent("Name", value: server.displayName)
                LabeledContent("System", value: diagnostics?.operatingSystem ?? (server.isConnected ? "Checking…" : "Connect to see"))
                LabeledContent("Bloom Server version", value: installedVersion)
                LabeledContent("Account", value: diagnostics?.account ?? summary.serviceUser)
                if !server.remoteDirectory.isEmpty {
                    LabeledContent("Data") {
                        Text(server.remoteDirectory).font(Typo.codeSmall).textSelection(.enabled)
                    }
                }
                if let diagnosticsFailure {
                    Text(diagnosticsFailure).settingsFootnote().textSelection(.enabled)
                }
            }
            Section {
                ForEach(summary.rows) { row in ServerSummaryRow(row: row) }
            } header: {
                HStack(spacing: Metrics.spacing) {
                    Text("What Bloom installed")
                    ServerSetupHelpButton(title: "Where everything is", details: summary.locationDetails)
                }
            }
            Section("Good to know") {
                ForEach(ServerInstallationSummary.limits) { row in ServerSummaryRow(row: row) }
            }
            Section("Uninstall") {
                if let setup = uninstall {
                    ServerUninstallView(setup: setup, serverName: server.displayName, removeFromThisMac: removeFromThisMac) {
                        setup.cancel()
                        uninstall = nil
                    }
                } else {
                    Text("Remove Bloom Server and its services from the server. You choose whether the account keeps its projects and data.")
                        .settingsFootnote()
                    Button("Uninstall Bloom Server…") { uninstall = ServerSetupModel.administrator(for: server) }
                        .disabled(server.isMaintainingServer)
                }
            }
        }
        .settingsForm()
        .task(id: server.connectionGeneration) { await loadDiagnostics() }
    }

    private func loadDiagnostics() async {
        guard server.isConnected else { diagnostics = nil; return }
        do {
            let result = try await server.read(.diagnostics, timeout: .seconds(30))
            guard case .diagnostics(let value) = result else { return }
            diagnostics = value
            diagnosticsFailure = nil
        } catch is CancellationError {
            // A server change replaces this request with the next one.
        } catch {
            diagnosticsFailure = "System details could not be loaded. " + error.localizedDescription
        }
    }
}
