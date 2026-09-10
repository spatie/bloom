import SwiftUI
import BloomCore
import UniformTypeIdentifiers

/// Installation and connection recovery share one flow, so retrying keeps the address and key.
struct ServerSetupView: View {
    @Bindable var model: ServerSetupModel
    let showAdvanced: () -> Void
    var windowID = ServerWindow.id
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var login: LoginTerminalSession?
    @State private var showsKeyPicker = false
    @State private var keySelectionFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                if model.phase == .introduction {
                    Label("Bloom Server", systemImage: "server.rack")
                        .font(Typo.captionEmphasis)
                        .foregroundStyle(Palette.accent)
                } else { setupProgress }
                Text(title).font(model.phase == .introduction ? Typo.displayHeading : Typo.heading)
                Text(subtitle)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.gutter * 2)

            if model.phase == .introduction {
                ServerSetupIntroduction(showAdvanced: showAdvanced)
            } else { Form {
                phaseContent
                if let failure = model.failure {
                    Section {
                        Label(failure.title, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Palette.warning)
                        Text(failure.message).textSelection(.enabled)
                        Text(failure.recovery).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if !model.progress.isEmpty {
                    DisclosureGroup("Setup details") {
                        ScrollView {
                            Text(model.progress.joined(separator: "\n"))
                                .font(Typo.codeSmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                    }
                }
            }
            .formStyle(.grouped)
            }

            Divider()
            HStack(spacing: Metrics.gutter) {
                Button("Cancel") {
                    model.cancel()
                    dismissWindow(id: windowID)
                }
                .keyboardShortcut(.cancelAction)
                if canEditAddress {
                    Button("Edit Address") { model.editAddress() }
                        .disabled(model.isBusy)
                }
                if model.phase == .address {
                    Button("Back") { model.showIntroduction() }
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                primaryButton
            }
            .padding(Metrics.gutter)
        }
        .frame(width: 680, height: 560)
        .sheet(isPresented: Binding(get: { login != nil }, set: { if !$0 { closeLogin() } })) {
            if let login {
                ServerSetupLoginView(session: login, close: closeLogin)
            }
        }
        .fileImporter(isPresented: $showsKeyPicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): model.identityFile = url.path; keySelectionFailure = nil
            case .failure: keySelectionFailure = "The SSH key file could not be selected. Try again or enter its full path."
            }
        }
        .task { if model.phase == .accounts { await model.refreshAccounts() } }
        .onDisappear {
            login?.stop()
            model.cancel()
        }
    }

    private var title: String {
        switch model.phase {
        case .introduction: "Keep your work running"
        case .address: "Add a Server"
        case .trust: "Verify Your Server"
        case .checking: "Checking Your Server"
        case .readyToInstall: "Prepare Your Server"
        case .installing: "Setting Up Bloom Server"
        case .accounts: "Connect Your Accounts"
        case .connecting: "Connecting to Your Server"
        case .complete: "Your Server Is Ready"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .introduction: "Run your projects on your own server, and pick up where you left off in Bloom."
        case .address: "Enter your Ubuntu server’s SSH address. Bloom will check it before making any changes."
        case .trust: "This is the first connection to this server. Compare its fingerprint with one provided by your administrator or hosting provider."
        case .checking: "Checking the operating system, access and any existing Bloom installation."
        case .readyToInstall: "Bloom will install its server component and tools, create a dedicated account, and configure automatic startup."
        case .installing: "Setup runs over SSH. Your projects will run under a dedicated server account."
        case .accounts: "Sign in on the server to use private GitHub repositories and your preferred agent."
        case .connecting: "Verifying that Bloom can reach the server and load your projects."
        case .complete: "Choose a repository and create a workspace. Setup and previews use the same flow as local workspaces."
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .introduction: EmptyView()
        case .address: addressFields
        case .trust:
            Section("Server identity") {
                LabeledContent("Address", value: model.host)
                Text(model.fingerprint ?? "No fingerprint was returned.")
                    .font(Typo.codeSmall).textSelection(.enabled)
                Text("Only continue if the fingerprint matches.").foregroundStyle(.secondary)
            }
        case .checking, .installing, .connecting:
            Section {
                Label(model.host, systemImage: "server.rack")
                if let latest = model.progress.last { Text(latest).foregroundStyle(.secondary) }
            }
        case .readyToInstall: installationSummary
        case .accounts: accountFields
        case .complete:
            Section {
                Label(model.label.isEmpty ? model.host : model.label, systemImage: "checkmark.circle")
                Text("Your processes can keep running when you close Bloom.").foregroundStyle(.secondary)
            }
        }
    }

    private var addressFields: some View {
        Section {
            TextField("SSH address", text: $model.host, prompt: Text("root@203.0.113.10 or SSH alias"))
                .help("Use an account with administrator access for installation.")
            TextField("Server label", text: $model.label, prompt: Text("Optional, for example Development"))
            DisclosureGroup("SSH key") {
                HStack {
                    TextField("Key file", text: $model.identityFile, prompt: Text("Use SSH configuration or your SSH agent"))
                    Button("Choose…") { showsKeyPicker = true }
                        .accessibilityLabel("Choose an SSH key file")
                }
                if let keySelectionFailure {
                    Text(keySelectionFailure).font(.caption).foregroundStyle(Palette.warning)
                }
                Text("An explicit key file is used directly, without the SSH agent. For 1Password or an encrypted key loaded in your agent, leave this empty and use your SSH configuration. Password-only connections need an SSH key first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Connect to an existing server with advanced settings…", action: showAdvanced)
                .buttonStyle(.link)
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var installationSummary: some View {
        if let check = model.check {
            Section("Server") {
                LabeledContent("Address", value: model.host)
                LabeledContent("System", value: "\(check.platform) (\(check.architecture))")
                if check.existing {
                    Text("An existing Bloom installation was found. Setup preserves its projects and workspaces.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Browser testing") {
                Toggle("Install browser testing tools", isOn: $model.installsBrowserTools)
                Text("Adds agent-browser and sandboxed Chrome so agents can inspect and test websites on this server. Browser previews in Bloom work independently.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Optional. Host workspaces are supported; Docker projects need separate browser dependencies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !check.blockers.isEmpty {
                Section("Before setup can continue") {
                    ForEach(check.blockers, id: \.code) { notice in
                        Label(notice.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Palette.warning)
                            .textSelection(.enabled)
                    }
                }
            }
            if !check.warnings.isEmpty {
                Section("Please check") {
                    ForEach(check.warnings, id: \.code) { notice in
                        Label(notice.message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var accountFields: some View {
        Section {
            accountRow("GitHub", detail: model.githubIsAuthenticated ? "Signed in on the server. Private repositories are available according to this account’s permissions." : "Browse and clone your private repositories.", account: .github)
            accountRow("Codex", detail: "Install and sign in to Codex on this server.", account: .codex)
            accountRow("Claude", detail: "Install and sign in to Claude on this server.", account: .claude)
            ForEach(model.accountChecks.filter { $0.id != .github }) { check in
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Label(check.title, systemImage: check.status == .ready ? "checkmark.circle" : "info.circle")
                    Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            browserStatus
            Button("Check Accounts") { Task { await model.refreshAccounts() } }
                .disabled(model.isBusy)
            Text("You can connect now and sign in later. GitHub is needed for private repositories; an authenticated agent is needed to start a chat.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accountRow(_ title: String, detail: String, account: ServerSetupAccount) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if account == .github, model.githubIsAuthenticated {
                Label("Signed In", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button(account == .github && model.githubIsAuthenticated ? "Change Account…" : "Sign In…") {
                guard let launch = model.accountTerminal(account) else { return }
                login = LoginTerminalSession(launch: launch, label: "\(title) on \(model.host)") { _ in }
            }
            .accessibilityLabel("Sign in to \(title) on the server")
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder private var browserStatus: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Label("Browser testing", systemImage: model.browserReadiness?.status == .ready ? "checkmark.circle" : "globe")
            if let failure = model.browserFailure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning).textSelection(.enabled)
                if let recovery = model.browserRecovery {
                    Text(recovery).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Bloom Server is ready. You can connect and add browser testing later.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.browserReadiness?.detail ?? "Optional browser testing is not installed. You can still preview websites in Bloom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.browserReadiness?.status != .ready, model.canInstallBrowser {
                Button(model.browserAttempted ? "Retry Browser Setup" : "Install Browser Tools") { Task { await model.retryBrowserInstall() } }
            }
        }
    }

    private var canEditAddress: Bool {
        switch model.phase {
        case .introduction, .address, .complete: false
        default: true
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if model.failure != nil {
            Button("Try Again") { Task { await model.retry() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        } else {
            switch model.phase {
            case .introduction:
                Button("Get Started") { model.beginSetup() }
                    .keyboardShortcut(.defaultAction)
            case .address:
                Button("Check Server") { Task { await model.inspect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            case .trust:
                Button("Trust and Continue") { Task { await model.trustHost() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.fingerprint == nil || model.isBusy)
            case .readyToInstall:
                Button("Set Up Server") { Task { await model.install() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.check == nil || model.check?.blockers.isEmpty == false || model.isBusy)
            case .accounts:
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConnect || model.isBusy)
            case .complete:
                Button("Choose a Repository…") {
                    StartProjectOpening.shared.isRemote = true
                    openWindow(id: StartProjectWindow.id)
                    dismissWindow(id: windowID)
                }
                .keyboardShortcut(.defaultAction)
            case .checking, .installing, .connecting:
                Text("Please wait…").foregroundStyle(.secondary)
            }
        }
    }

    private func closeLogin() {
        login?.stop()
        login = nil
        Task { await model.refreshAccounts() }
    }

    private var setupStep: Int {
        switch model.phase {
        case .introduction, .address, .trust, .checking: 0
        case .readyToInstall, .installing: 1
        case .accounts, .connecting: 2
        case .complete: 3
        }
    }

    private var setupProgress: some View {
        HStack(spacing: Metrics.gutter) {
            ForEach(Array(["Server", "Setup", "Accounts"].enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.right").font(Typo.micro).foregroundStyle(Palette.textTertiary)
                }
                HStack(spacing: Metrics.spacingSmall) {
                    if index < setupStep { Image(systemName: "checkmark.circle.fill") }
                    Text(name)
                }
                .font(Typo.captionEmphasis)
                .foregroundStyle(index == setupStep ? Palette.accent : Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(setupStep == 3 ? "Setup complete" : "Step \(setupStep + 1) of 3")
        .padding(.bottom, Metrics.spacing)
    }
}

struct ServerSetupLoginView: View {
    let session: LoginTerminalSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text(session.label).font(Typo.heading)
            Text("Follow the prompts below. Open any sign-in link in your browser and return here when finished.")
                .foregroundStyle(.secondary)
            LoginTerminal(session: session)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
            if !session.isRunning {
                Text("The sign-in command finished. Close this window to check the server accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(session.isRunning ? "Close" : "Check Accounts", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.gutter * 2)
        .frame(width: 660)
    }
}
