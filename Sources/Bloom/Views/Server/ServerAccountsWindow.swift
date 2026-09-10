import SwiftUI
import AppKit

/// Existing server accounts have their own destination, without entering installation setup.
struct ServerAccountsWindow: Scene {
    static let id = "bloom-server-accounts"
    let model: AppModel

    var body: some Scene {
        Window("Server Accounts", id: Self.id) {
            ServerAccountsContent(server: model.remoteServer)
                .id(model.remoteServer.connectionProfile?.id)
                .environment(model)
                .windowRole(.utility)
        }
        .windowResizability(.contentSize)
    }
}

private struct ServerAccountsContent: View {
    let server: ServerWindowModel
    @State private var setup: ServerSetupModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    init(server: ServerWindowModel) {
        self.server = server
        _setup = State(initialValue: ServerSetupModel(server: server, resumeExisting: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Server accounts").font(Typo.heading)
            Text(server.displayName).font(Typo.label).foregroundStyle(.secondary)
            if setup.hasInstalledServer {
                Text("These sign-ins belong to \(setup.host). Your Mac’s accounts are separate.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.gutter) {
                        if let failure = setup.failure { ServerSetupFailureView(failure: failure) }
                        ServerSetupAccountsView(model: setup)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Text("Sign-in requires this server’s SSH connection, client key and verified host key. HTTPS connections cannot open an interactive server sign-in session.")
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Button("Server Connection…") { openWindow(id: ServerWindow.id) }
                Spacer()
            }
            HStack {
                if !setup.activity.lines.isEmpty || setup.failure != nil {
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(setup.diagnosticReport, forType: .string)
                    }
                }
                Spacer(); Button("Done") { dismissWindow(id: ServerAccountsWindow.id) }.keyboardShortcut(.cancelAction) }
        }
        .padding(Metrics.gutter * 2)
        .frame(width: 660, height: 520)
        .task { await setup.refreshAccounts() }
        .onDisappear { setup.cancel() }
    }
}
