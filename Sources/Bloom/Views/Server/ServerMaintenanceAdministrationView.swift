import SwiftUI
import BloomCore

/// Maintenance stays inside Updates, using the same trust, installer and diagnostic model as setup.
struct ServerMaintenanceAdministrationView: View {
    @Bindable var setup: ServerSetupModel
    let isStarting: Bool
    let review: () -> Void
    let recover: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text(setup.label.isEmpty ? setup.host : setup.label).font(Typo.labelEmphasis)
            if setup.phase == .complete {
                Label("Bloom Server is running and connected", systemImage: "checkmark.circle")
                Text("Your projects and conversations are ready.").settingsFootnote()
                if let failure = setup.failure { ServerSetupFailureView(failure: failure) }
                Button("Done", action: finish)
            } else if setup.isBusy {
                ProgressView(setup.phase == .checking ? "Checking administrator access…" : isStarting ? "Starting and reconnecting…" : "Updating and reconnecting…")
                    .controlSize(.small)
                Text(setup.phase == .checking ? "This checks the server without changing it." : "Keep this Mac connected until this step finishes. Bloom will restore the connection automatically.").settingsFootnote()
                if !setup.activity.lines.isEmpty {
                    ServerSetupActivityView(activity: setup.activity, failure: setup.failure, compact: true)
                        .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
                }
            } else {
                Text(isStarting ? "Start the existing service without reinstalling it. Bloom will reconnect this Mac when it is ready."
                     : "Install the maintenance service so future updates can run independently of this Mac. Bloom handles stopping, updating and starting the server.")
                    .settingsFootnote()
                TextField("Administrator SSH address", text: $setup.host, prompt: Text("root@server.example.com"))
                    .textFieldStyle(.roundedBorder)
                TextField("Private key file (optional)", text: $setup.identityFile, prompt: Text("Use this Mac’s SSH agent"))
                    .textFieldStyle(.roundedBorder)
                Text("Use root or an administrator with passwordless sudo. The saved workspace connection is kept separately.").settingsFootnote()
                if setup.phase == .trust {
                    Text("Verify this server’s SSH fingerprint before trusting it.").font(Typo.labelEmphasis)
                    Text(setup.fingerprint ?? "Fingerprint unavailable").font(Typo.codeSmall).textSelection(.enabled)
                    Button("Trust and Check Server") { Task { await setup.trustHost() } }
                } else {
                    Button(setup.check == nil ? "Check Server" : "Check Again") { Task { await setup.inspect() } }
                }
                if let check = setup.check {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installation: " + (check.installationRoot ?? check.executable)).textSelection(.enabled)
                        Text("Project data: " + check.dataDirectory).textSelection(.enabled)
                        Text("Account: " + check.serviceUser)
                    }.font(Typo.caption).foregroundStyle(.secondary)
                    ForEach(Array(check.blockers.enumerated()), id: \.offset) { _, blocker in
                        if blocker.code != "server_running" {
                            Text(blocker.message).foregroundStyle(Palette.warning).textSelection(.enabled)
                            Text(blocker.recoverySuggestion).settingsFootnote().textSelection(.enabled)
                        }
                    }
                    if check.existing, !setup.canMaintainExistingServer, check.blockers.allSatisfy({ $0.code == "server_running" }) {
                        Text("This installation does not match the saved SSH host and data directory. Check the address before continuing.")
                            .foregroundStyle(Palette.warning).textSelection(.enabled)
                    }
                    if !check.existing {
                        Text("No existing Bloom installation was found. Add a new server from the sidebar to install it.").settingsFootnote()
                    }
                    if !isStarting {
                        Text("Installs the Bloom Server package included with this app and its managed update service. Projects, GitHub and agent sign-ins are preserved. Docker and agent tools are not updated in this step.").settingsFootnote()
                    }
                    Button(isStarting ? "Start and Reconnect…" : "Review Update…", action: review)
                        .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                        .disabled(!setup.canMaintainExistingServer)
                }
                if let failure = setup.failure {
                    ServerSetupFailureView(failure: failure)
                    if !isStarting { Button("Recover Server Without Updating", action: recover) }
                }
                if !setup.activity.lines.isEmpty {
                    DisclosureGroup("Server output") {
                        ScrollView {
                            Text(setup.activity.output).font(Typo.codeSmall).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 100, maxHeight: 220)
                    }
                }
                Button("Back to Updates", action: finish)
            }
        }
    }
}
