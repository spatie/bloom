import SwiftUI
import BloomCore

/// Shared by first setup and existing-server settings. Sign-ins run as the server account.
struct ServerSetupAccountsView: View {
    @Bindable var model: ServerSetupModel
    @State private var login: LoginTerminalSession?
    @State private var loginProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            accountRow("GitHub", detail: githubDetail, account: .github)
            Divider()
            accountRow("Codex", detail: "Connect your Codex account. The tool installs if needed.", account: .codex)
            Divider()
            accountRow("Claude", detail: "Connect your Claude account. The tool installs if needed.", account: .claude)
            Divider()
            browserRow
            HStack {
                Button("Refresh Status") { Task { await model.refreshAccounts() } }.disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            if let loginProblem { Text(loginProblem).font(Typo.caption).foregroundStyle(Palette.warning).textSelection(.enabled) }
        }
        .sheet(isPresented: Binding(get: { login != nil }, set: { if !$0 { closeLogin() } })) {
            if let login { ServerSetupLoginView(session: login, close: closeLogin) }
        }
        .onDisappear { login?.stop(); login = nil }
    }

    private var githubDetail: String {
        model.githubIsAuthenticated ? "Signed in on this server. Private repositories are available." : "Connect GitHub to browse and clone your private repositories."
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
            if model.browserReadiness?.status != .ready, model.canInstallBrowser {
                Button(model.browserAttempted ? "Retry Browser Setup" : "Install Browser Tools") { Task { await model.retryBrowserInstall() } }
            }
        }
    }

    private func closeLogin() {
        login?.stop()
        login = nil
        Task { await model.refreshAccounts() }
    }
}
