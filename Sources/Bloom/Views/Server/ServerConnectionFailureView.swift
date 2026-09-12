import SwiftUI
import BloomCore

/// A connection failure stays inspectable while automatic retries run in the background.
struct ServerConnectionFailureView: View {
    let server: ServerWindowModel
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    private var details: String {
        ServerSetupDiagnostics.sanitise(server.connectionRecovery.lastError ?? server.error ?? "The server is disconnected.")
    }

    private var advice: String {
        if !server.usesHTTPS {
            let failure = ServerSetupFailure.classify(status: 0, stderr: details)
            switch failure.code {
            case .authentication:
                return failure.recovery + " If the server was reset, run Guided Setup in Server Settings."
            case .hostUnknown, .hostChanged, .unreachable: return failure.recovery
            default: break
            }
        }
        return server.connectionRecovery.automaticallyRetries
            ? "Bloom will retry automatically. You can also retry now or check the connection settings."
            : "Check the connection settings, then try again."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server.connectionRecovery.hasConnected ? "Connection interrupted" : "Could not connect")
                .font(.headline)
            Text(server.displayName).font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                Text(details).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            Text(advice)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied" : "Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details, forType: .string)
                    copied = true
                }
                Button("Settings…") { openWindow(id: ServerWindow.id) }
                Spacer()
                Button("Retry Now") { Task { await server.connect() } }
                    .disabled(server.isConnecting || server.isDisconnecting || server.isRemovingServer)
            }
        }
        .padding(16)
        .frame(width: 390)
        .onChange(of: details) { copied = false }
    }
}
