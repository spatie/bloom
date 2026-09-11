import SwiftUI
import BloomCore

/// Shared by first setup and existing-server settings. Sign-ins run as the server account.
struct ServerSetupAccountsView: View {
    @Bindable var model: ServerSetupModel
    @State private var login: LoginTerminalSession?
    @State private var loginProblem: String?
    @State private var credentialImport: ServerCredentialImportModel?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            if !model.hasChosenAccountMethod {
                if model.swapDiagnostic != nil { swapRow }
                if model.dockerDiagnostic != nil { dockerRow }
                if model.browserDiagnostic != nil { browserRow }
                accountChoice
            } else {
                signIns
            }
        }
        .sheet(isPresented: Binding(get: { login != nil }, set: { if !$0 { closeLogin() } })) {
            if let login { ServerSetupLoginView(session: login, close: closeLogin) }
        }
        .sheet(isPresented: Binding(get: { credentialImport != nil }, set: { if !$0 { closeImport() } })) {
            if let credentialImport { ServerCredentialImportView(model: credentialImport, close: closeImport) }
        }
        .onDisappear { login?.stop(); login = nil; credentialImport?.cancel(); credentialImport = nil }
    }

    private var accountChoice: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter * 1.5) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40)).foregroundStyle(Palette.controlAccent).accessibilityHidden(true)
            Text("Bring your accounts with you").font(Typo.heading)
            Text("Copy your GitHub and Codex sign-ins from this Mac. You choose which accounts to share, and this Mac stays signed in.")
                .font(Typo.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Copy Accounts from This Mac…") {
                guard let connection = model.accountConnection else { return }
                credentialImport = ServerCredentialImportModel(connection: connection)
            }
            .buttonStyle(.borderedProminent).tint(Palette.controlAccent)
            .disabled(model.isBusy || model.accountConnection == nil)
            Text("Prefer to sign in separately? Choose Continue. You can also connect Claude on the next screen.")
                .font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signIns: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            accountRow("GitHub", detail: githubDetail, account: .github)
            Divider()
            accountRow("Codex", detail: agentDetail(.codex, name: "Codex"), account: .codex)
            Divider()
            accountRow("Claude", detail: agentDetail(.claudeCode, name: "Claude"), account: .claude)
            Divider()
            browserRow
            if model.installsDocker || model.dockerAttempted {
                Divider()
                dockerRow
            }
            if model.swapAttempted {
                Divider()
                swapRow
            }
            HStack {
                Button("Refresh Status") { Task { await model.refreshAccounts() } }.disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Copy Accounts from This Mac…") {
                    guard let connection = model.accountConnection else { return }
                    credentialImport = ServerCredentialImportModel(connection: connection)
                }
                .buttonStyle(.link).font(Typo.caption)
                .disabled(model.isBusy || model.accountConnection == nil)
            }
            if let loginProblem { Text(loginProblem).font(Typo.caption).foregroundStyle(Palette.warning).textSelection(.enabled) }
        }
    }

    private var githubDetail: String {
        model.githubIsAuthenticated ? "Signed in on this server. Private repositories are available." : "Connect GitHub to browse and clone your private repositories."
    }

    private func agentDetail(_ agent: AgentKind, name: String) -> String {
        guard let status = model.agentAuthentication.first(where: { $0.agent == agent }) else {
            return "Connect your \(name) account. The tool installs if needed."
        }
        switch status.state {
        case .ready: return "A saved sign-in is available on this server."
        case .signInRequired: return "Sign in before starting an agent chat on this server."
        case .unavailable: return "The tool will be installed when you sign in."
        case .unknown: return "Sign-in status could not be checked. You can sign in or refresh to try again."
        }
    }

    private func accountRow(_ title: String, detail: String, account: ServerSetupAccount) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(title).font(Typo.labelEmphasis)
                Text(detail).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button(account == .github && model.githubIsAuthenticated ? "Change Account…" : "Sign In…") {
                guard let launch = model.accountTerminal(account) else {
                    loginProblem = "This connection cannot open a server sign-in session. Use the SSH connection configured for this server account."
                    return
                }
                loginProblem = nil
                login = LoginTerminalSession(launch: launch, label: "\(title) on \(model.host)") { _ in }
            }
            .disabled(model.isBusy)
        }
    }

    private var browserRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Label(model.browserFailure == nil ? "Browser testing (optional)" : "Optional browser tools need attention",
                      systemImage: model.browserReadiness?.status == .ready ? "checkmark.circle.fill" : model.browserFailure != nil ? "exclamationmark.triangle" : "globe")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(model.browserFailure != nil ? Palette.warning : Palette.textPrimary)
                if model.browserFailure != nil {
                    Text("Bloom Server is ready. You can sign in and start working while browser testing is repaired.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                }
                Text(model.browserFailure ?? model.browserReadiness?.detail ?? "You can preview websites in Bloom without installing browser testing tools.")
                    .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let command = model.browserDiagnostic?.command {
                    Text(command).font(Typo.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let recovery = model.browserRecovery { Text(recovery).font(Typo.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if model.browserReadiness?.status != .ready, model.canInstallOptionalTools {
                Button(model.browserAttempted ? "Retry Browser Setup" : "Install Browser Tools") { Task { await model.retryBrowserInstall() } }
            }
        }
    }

    private var dockerRow: some View {
        optionalToolRow("Docker", ready: model.dockerReady, diagnostic: model.dockerDiagnostic,
            detail: model.dockerReady ? "Rootless Docker and Compose are ready for container projects." : "Install Docker to run container projects on this server.",
            recoveryNote: "You can continue. Projects that require Docker will need this setup to finish first.",
            buttonTitle: model.dockerAttempted ? "Retry Docker Setup" : "Install Docker",
            symbol: "shippingbox") { Task { await model.retryDockerInstall() } }
    }

    private var swapRow: some View {
        optionalToolRow("Swap", ready: model.swapReady, diagnostic: model.swapDiagnostic,
            detail: model.swapStatusMessage ?? "Swap setup has not finished.",
            recoveryNote: "You can continue without swap. Retry when the server has enough free disk space and supports swap files.",
            buttonTitle: "Retry Swap Setup", symbol: "internaldrive") { Task { await model.retrySwapInstall() } }
    }

    private func optionalToolRow(_ title: String, ready: Bool, diagnostic: ServerSetupFailure?,
                                 detail: String, recoveryNote: String, buttonTitle: String, symbol: String,
                                 retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Label(diagnostic == nil ? title + " (optional)" : title + " needs attention",
                      systemImage: ready ? "checkmark.circle.fill" : diagnostic != nil ? "exclamationmark.triangle" : symbol)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(diagnostic != nil ? Palette.warning : Palette.textPrimary)
                Text(diagnostic?.message ?? detail)
                    .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let diagnostic {
                    Text(recoveryNote).font(Typo.caption).foregroundStyle(.secondary)
                    if let command = diagnostic.command { Text(command).font(Typo.codeSmall).textSelection(.enabled) }
                    Text(diagnostic.recovery).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if !ready, model.canInstallOptionalTools { Button(buttonTitle, action: retry) }
        }
    }

    private func closeImport() {
        credentialImport?.cancel()
        credentialImport = nil
        model.hasChosenAccountMethod = true
        Task { await model.refreshAccounts() }
    }

    private func closeLogin() {
        login?.stop()
        login = nil
        Task { await model.refreshAccounts() }
    }
}
