import SwiftUI
import BloomCore

/// Settings > GitHub & GitLab: the accounts gh and glab are signed in as, and the sheet that
/// installs either, signs in, reconnects or switches account. Shown whether or not either is
/// installed, because a missing CLI is exactly when somebody comes looking.
struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var gitHubUser = GitHubIdentity.cachedUsername
    @State private var gitLabInstalled = GitLab.isInstalled
    /// What the launch read, else nil until glab has answered, which an unreachable host can hold
    /// up for seconds.
    @State private var gitLabAccounts: [String: String]? = GitLabIdentity.usernames.isEmpty ? nil : GitLabIdentity.usernames
    @State private var signIn: GitHubSignIn.Request?

    var body: some View {
        ConnectionsForm(
            gitHub: GitHubAvailability.shared.state, gitHubUser: gitHubUser,
            gitLabInstalled: gitLabInstalled, gitLabAccounts: gitLabAccounts
        ) { signIn = $0 }
        .task { await refresh(force: false) }
        .sheet(item: $signIn) { request in
            GitHubSignInSheet(request: request) { _ in
                signIn = nil
                Task { await refresh(force: true) }
            }
        }
    }

    /// - Parameter force: after the sheet, which may have signed somebody in, out or over.
    private func refresh(force: Bool) async {
        let state = await GitHubAvailability.shared.check(force: force)
        if state == .ready, force || GitHubIdentity.cachedUsername == nil {
            await GitHubIdentity.resolve(force: true)
        }
        gitHubUser = GitHubIdentity.cachedUsername
        gitLabInstalled = GitLab.isInstalled
        gitLabAccounts = await app.gitLabAccounts()
    }
}

/// The pane as drawn from what it is given, so `Gallery.connections` can draw every state of it.
struct ConnectionsForm: View {
    let gitHub: GitHubAvailability.State
    let gitHubUser: String?
    let gitLabInstalled: Bool
    /// Host to username, or nil while glab is still being asked.
    let gitLabAccounts: [String: String]?
    let present: (GitHubSignIn.Request) -> Void

    var body: some View {
        Form {
            Section {
                SettingsRow("Account") {
                    account(gitHubLine) { gitHubButtons }
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Pull requests, checks and merges go through the GitHub CLI, gh.").settingsFootnote()
            }

            Section {
                if let gitLabLine {
                    SettingsRow("Account") {
                        account(gitLabLine) {
                            if gitLabAccounts != nil || !gitLabInstalled {
                                Button(gitLabInstalled ? "Sign in…" : "Install glab…") {
                                    ask(.gitLab, access: gitLabInstalled ? .signedOut : .notInstalled)
                                }
                            }
                        }
                    }
                }
                ForEach((gitLabAccounts ?? [:]).sorted { $0.key < $1.key }, id: \.key) { host, username in
                    SettingsRow(host) {
                        account(username) {
                            Button("Reconnect…") { ask(.gitLab, access: .ready, host: host) }
                        }
                    }
                }
                if gitLabInstalled, gitLabAccounts?.isEmpty == false {
                    Button("Sign in to another host…") { ask(.gitLab, access: .signedOut) }
                }
            } header: {
                Text("GitLab")
            } footer: {
                Text("Merge requests and pipelines, for projects on GitLab, go through the GitLab CLI, glab. It keeps one account per host: to switch, reconnect and sign in as the other.")
                    .settingsFootnote()
            }
        }
        .settingsForm()
    }

    private func account(_ line: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: Metrics.gutter) {
            Text(line)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            actions()
        }
    }

    /// The one row GitLab has when no account is listed, or nil when they are.
    private var gitLabLine: String? {
        guard gitLabInstalled else { return "GitLab CLI not installed" }
        guard let gitLabAccounts else { return "Checking…" }
        return gitLabAccounts.isEmpty ? "Not signed in" : nil
    }

    private var gitHubLine: String {
        switch gitHub {
        case .unknown: "Checking…"
        case .notInstalled: "GitHub CLI not installed"
        case .signedOut: "Not signed in"
        case .ready: gitHubUser ?? "Signed in"
        }
    }

    @ViewBuilder
    private var gitHubButtons: some View {
        switch gitHub {
        case .unknown:
            EmptyView()
        case .notInstalled:
            Button("Install gh…") { ask(.gitHub, access: .notInstalled) }
        case .signedOut:
            Button("Sign in…") { ask(.gitHub, access: .signedOut) }
        case .ready:
            Button("Reconnect…") { ask(.gitHub, access: .ready) }
            Button("Switch Account…") { ask(.gitHub, access: .ready, purpose: .switchAccount) }
        }
    }

    private func ask(
        _ forge: Forge, access: GitHubAvailability.State, host: String? = nil,
        purpose: GitHubSignIn.Purpose = .connect
    ) {
        present(GitHubSignIn.Request(
            access: access, directory: AgentScratchDirectory.current(), forge: forge, host: host, purpose: purpose
        ))
    }
}
