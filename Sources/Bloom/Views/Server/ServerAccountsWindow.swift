import SwiftUI
import AppKit

/// Existing server accounts have their own destination, without entering installation setup.
struct ServerAccountsWindow: Scene {
    static let id = "bloom-server-accounts"
    let model: AppModel

    var body: some Scene {
        Window("Server Accounts", id: Self.id) {
            ServerAccountsContent(server: model.remoteServer)
                .frame(width: 660, height: 520)
                .id(model.remoteServer.connectionProfile?.id)
                .environment(model)
                .windowRole(.utility)
        }
        .windowResizability(.contentSize)
    }
}

struct ServerAccountsContent: View {
    let server: ServerWindowModel
    let embedded: Bool
    let showConnection: (() -> Void)?
    @State private var setup: ServerSetupModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    init(server: ServerWindowModel, embedded: Bool = false, showConnection: (() -> Void)? = nil) {
        self.server = server
        self.embedded = embedded
        self.showConnection = showConnection
        _setup = State(initialValue: ServerSetupModel(server: server, resumeExisting: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if setup.hasInstalledServer {
                    Section {
                        if let failure = setup.failure { ServerSetupFailureView(failure: failure) }
                        ServerSetupAccountsView(model: setup)
                    } header: {
                        Text("GitHub and AI agents")
                    } footer: {
                        Text("These accounts are used by workspaces running as \(setup.host).")
                            .settingsFootnote()
                    }
                } else {
                    Section("Sign in on the server") {
                        Text("Sign-in requires this server’s SSH connection, client key and verified host key. HTTPS connections cannot open an interactive server sign-in session.")
                            .settingsFootnote().textSelection(.enabled)
                        Button("Connection Settings") {
                            if let showConnection { showConnection() } else { openWindow(id: ServerWindow.id) }
                        }
                    }
                }
            }
            .settingsForm()
            if !embedded || !setup.activity.lines.isEmpty || setup.failure != nil {
                HStack {
                    if !setup.activity.lines.isEmpty || setup.failure != nil {
                        Button("Copy Report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setup.diagnosticReport, forType: .string)
                        }
                    }
                    Spacer()
                    if !embedded {
                        Button("Done") { dismissWindow(id: ServerAccountsWindow.id) }
                            .keyboardShortcut(.cancelAction)
                    }
                }.padding(Metrics.gutter)
            }
        }
        .task { await setup.refreshAccounts() }
        .onDisappear { setup.cancel() }
    }
}
