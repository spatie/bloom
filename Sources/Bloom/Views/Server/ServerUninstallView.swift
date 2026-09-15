import SwiftUI
import BloomCore

/// Uninstalling reuses setup's administrator check, so the confirmation describes the installation
/// that check verified, with its account and paths, rather than what this Mac remembers about it.
struct ServerUninstallView: View {
    @Bindable var setup: ServerSetupModel
    let serverName: String
    let removeFromThisMac: () -> Void
    let finish: () -> Void
    @State private var deletesData = false
    @State private var confirmsUninstall = false
    @State private var confirmsForce = false
    @State private var confirmsRemoval = false

    private var plan: ServerUninstallPlan? {
        setup.check.map { ServerUninstallPlan(check: $0, deletesData: deletesData) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            if let outcome = setup.uninstallOutcome {
                result(outcome)
            } else if setup.isUninstalling {
                running
            } else {
                preparation
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(plan?.confirmationTitle(server: serverName) ?? "Uninstall Bloom Server?",
                            isPresented: $confirmsUninstall, titleVisibility: .visible) {
            Button(plan?.confirmationButton ?? "Uninstall", role: .destructive) {
                Task { await setup.uninstall(deletesData: deletesData, force: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((plan?.confirmationMessage ?? "") + "\n\nServer: " + setup.host)
        }
        .confirmationDialog(ServerUninstallPlan.forceTitle, isPresented: $confirmsForce, titleVisibility: .visible) {
            Button(ServerUninstallPlan.forceButton, role: .destructive) {
                Task { await setup.uninstall(deletesData: deletesData, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ServerUninstallPlan.forceMessage)
        }
        .confirmationDialog("Remove \(serverName) from this Mac?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Server", role: .destructive, action: removeFromThisMac)
            Button("Keep", role: .cancel) {}
        } message: {
            Text(ServerUninstallOutcome.removalPrompt)
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Bloom signs in with administrator access to remove what it installed. Check the server first, then choose what happens to your projects.")
                .settingsFootnote().fixedSize(horizontal: false, vertical: true)
            TextField("Administrator SSH address", text: $setup.host, prompt: Text("root@server.example.com"))
                .textFieldStyle(.roundedBorder)
            TextField("Private key file (optional)", text: $setup.identityFile, prompt: Text("Use this Mac’s SSH agent"))
                .textFieldStyle(.roundedBorder)
            if setup.phase == .trust {
                Text("Verify this server’s SSH fingerprint before trusting it.").font(Typo.labelEmphasis)
                Text(setup.fingerprint ?? "Fingerprint unavailable").font(Typo.codeSmall).textSelection(.enabled)
                Button("Trust and Check Server") { Task { await setup.trustHost() } }
                    .disabled(setup.fingerprint == nil || setup.isBusy)
            } else {
                HStack(spacing: Metrics.spacing) {
                    Button(setup.check == nil ? "Check Server" : "Check Again") { Task { await setup.inspect() } }
                        .disabled(setup.isBusy || setup.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if setup.isBusy {
                        ProgressView().controlSize(.small)
                        Text("Checking administrator access…").settingsFootnote()
                    }
                }
            }
            if let check = setup.check, let plan, !setup.isBusy {
                checked(check, plan: plan)
            }
            if let failure = setup.failure {
                ServerSetupFailureView(failure: failure)
                if let code = setup.uninstallRefusalCode, ServerUninstallPlan.canForce(afterFailure: code) {
                    Button(ServerUninstallPlan.forceButton + "…") { confirmsForce = true }
                        .disabled(!setup.canUninstall)
                }
            }
            if !setup.activity.lines.isEmpty {
                DisclosureGroup("Server output") { ServerSetupLogView(activity: setup.activity) }
            }
            Button("Cancel", action: finish).disabled(setup.isBusy)
        }
    }

    @ViewBuilder private func checked(_ check: ServerInstallCheck, plan: ServerUninstallPlan) -> some View {
        if !check.existing {
            Text("No Bloom Server installation was found at this address. There is nothing to uninstall.")
                .settingsFootnote().fixedSize(horizontal: false, vertical: true)
        } else if !setup.canUninstall {
            Text(check.privilege == "none"
                 ? "This login has no administrator access. Use root, or an account with sudo that doesn’t ask for a password."
                 : "This installation doesn’t match \(serverName). Check the address before continuing.")
                .foregroundStyle(Palette.warning).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(check.blockers.filter { ["server_busy", "maintenance_busy"].contains($0.code) }, id: \.code) { notice in
                Text(notice.message + " Bloom asks before stopping them.")
                    .settingsFootnote().fixedSize(horizontal: false, vertical: true)
            }
            Picker("Projects and data", selection: $deletesData) {
                Text("Keep the \(plan.serviceUser) account and its data").tag(false)
                Text("Delete the \(plan.serviceUser) account and all of its data").tag(true)
            }
            .pickerStyle(.radioGroup)
            itemList("Removes", items: plan.removed, symbol: "minus.circle")
            itemList("Keeps", items: plan.kept, symbol: "checkmark.circle")
            Button(plan.confirmationButton + "…", role: .destructive) { confirmsUninstall = true }
                .disabled(!setup.canUninstall)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            HStack(spacing: Metrics.spacing) {
                ProgressView().controlSize(.small)
                Text("Uninstalling Bloom Server…").font(Typo.labelEmphasis)
            }
            Text(setup.activity.currentMessage).settingsFootnote().fixedSize(horizontal: false, vertical: true)
            Text("Keep this window open until it finishes.").settingsFootnote()
            ServerSetupLogView(activity: setup.activity)
        }
    }

    private func result(_ outcome: ServerUninstallOutcome) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Label(outcome.title, systemImage: "checkmark.circle.fill")
                .font(Typo.labelEmphasis).foregroundStyle(Palette.controlAccent)
            Text(outcome.message).settingsFootnote().textSelection(.enabled)
            if !outcome.removed.isEmpty { bullets("Removed", outcome.removed) }
            if !outcome.kept.isEmpty { bullets("Kept on the server", outcome.kept) }
            HStack {
                Button("Remove from This Mac…") { confirmsRemoval = true }
                Button("Done", action: finish)
            }
            if !setup.activity.lines.isEmpty {
                DisclosureGroup("Server output") { ServerSetupLogView(activity: setup.activity) }
            }
        }
    }

    private func itemList(_ title: String, items: [ServerUninstallPlan.Item], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(title).font(Typo.labelEmphasis)
            ForEach(items) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(Typo.captionEmphasis)
                        Text(item.detail).font(Typo.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bullets(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(title).font(Typo.captionEmphasis)
            ForEach(items, id: \.self) { item in
                Text("• " + item).font(Typo.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
