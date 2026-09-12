import SwiftUI
import AppKit
import BloomCore
import BloomUI
import UniformTypeIdentifiers

/// One decision per page. Progress and failures share a fixed, visible output pane.
struct ServerSetupView: View {
    @Bindable var model: ServerSetupModel
    let showAdvanced: () -> Void
    var windowID = ServerWindow.id
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var showsKeyPicker = false
    @State private var keySelectionFailure: String?
    @State private var confirmsStopServer = false
    @FocusState private var addressIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ServerSetupSteps(current: setupStep)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Metrics.spacing) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title).font(model.phase == .introduction ? Typo.displayHeading : Typo.heading)
                                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                            Spacer()
                            if model.phase != .introduction && model.phase != .address && model.phase != .checking {
                                Text(model.label.isEmpty ? model.host : "\(model.label) · \(model.host)")
                                    .font(Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 180, alignment: .trailing)
                                    .help(model.label.isEmpty ? model.host : "\(model.label) · \(model.host)")
                            }
                        }
                        if !subtitle.isEmpty {
                            Text(subtitle).font(Typo.label).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter * 2)
                    .padding(.vertical, Metrics.gutter * 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if model.phase == .introduction {
                            ServerSetupIntroduction(showAdvanced: showAdvanced)
                        } else if model.phase == .installing || model.isInstallingOptionalTools {
                            ServerSetupActivityView(activity: model.activity, failure: model.failure ?? model.optionalDiagnostic, compact: true)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: Metrics.gutter * 1.5) {
                                    if let failure = model.failure { ServerSetupFailureView(failure: failure) }
                                    phaseContent
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollClipDisabled()
                        }
                    }
                    .padding(.horizontal, Metrics.gutter * 2)
                    .padding(.bottom, Metrics.gutter * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            Divider()
            HStack(spacing: Metrics.gutter) {
                if model.phase != .complete {
                    Button(model.isStopping ? "Stopping…" : model.isBusy ? "Stop Setup" : "Cancel") {
                        if model.isBusy { Task { await model.stopSetup() } } else { model.cancel(); dismissWindow(id: windowID) }
                    }
                    .keyboardShortcut(.cancelAction).disabled(model.isStopping)
                }
                if model.failure != nil || !model.activity.lines.isEmpty {
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
                    }
                    .help("Copy setup steps, server output and error details")
                }
                Spacer()
                if model.phase != .introduction && model.phase != .complete {
                    Button("Back") {
                        if model.phase == .accounts && model.hasChosenAccountMethod { model.hasChosenAccountMethod = false } else { Task { await model.goBack() } }
                    }.disabled(!model.canGoBack)
                }
                primaryButton.buttonStyle(.borderedProminent).tint(Palette.controlAccent)
            }
            .padding(Metrics.gutter)
        }
        .frame(width: 840, height: 640)
        .confirmationDialog("Stop Bloom Server on \(model.label.isEmpty ? model.host : model.label)?", isPresented: $confirmsStopServer) {
            Button("Stop Server", role: .destructive) { Task { await model.stopServer() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Connected clients will disconnect, and server terminal commands may stop. Bloom checks for active agents and workspace setup first. Your projects and conversations stay on the server. Installing the update starts it again.")
        }
        .fileImporter(isPresented: $showsKeyPicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): model.identityFile = url.path; keySelectionFailure = nil
            case .failure: keySelectionFailure = "The key file could not be selected. Try again or enter its full path."
            }
        }
        .task { focusEmptyAddress(); if model.phase == .accounts { await model.refreshAccounts() } }
        .onChange(of: model.phase) { _, _ in focusEmptyAddress() }
        .onDisappear { model.cancel() }
    }

    private func focusEmptyAddress() {
        guard model.phase == .address, model.host.isEmpty else { return }
        addressIsFocused = true
    }

    private var title: String {
        switch model.phase {
        case .introduction: "Keep your work running"
        case .address, .checking: "Connect your server"
        case .trust: "Verify the server identity"
        case .readyToInstall: model.hasInstalledServer ? "Server installed" : "Install Bloom Server"
        case .installing: model.failure == nil ? "Installing Bloom Server" : "Setup stopped"
        case .accounts: accountsTitle
        case .connecting: "Connecting to Bloom Server"
        case .complete: "Your server is ready"
        }
    }

    private var accountsTitle: String {
        if model.isInstallingSwap { return "Preparing swap space" }
        if model.isInstallingDocker { return "Installing Docker" }
        if model.isInstallingBrowser { return "Installing browser tools" }
        return model.hasChosenAccountMethod ? "Sign in on your server" : "Set up your accounts"
    }

    private var subtitle: String {
        switch model.phase {
        case .introduction: "Run projects on your server and pick up where you left off on any device."
        case .address, .checking: "Enter an Ubuntu server with administrator SSH access. This step only checks the server."
        case .trust: "Check this fingerprint in your server console or with your administrator before continuing."
        case .readyToInstall: model.hasInstalledServer ? "Your installation and sign-ins are preserved. Continue to finish connecting." : "Check what will be installed, then choose Install."
        case .accounts: model.isInstallingOptionalTools || !model.hasChosenAccountMethod ? "" : "Check your accounts below. You can connect more tools later."
        case .installing, .connecting: ""
        case .complete: "Choose a repository to start your first remote workspace."
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .introduction, .installing: EmptyView()
        case .address, .checking:
            addressFields
            serverChecks
        case .trust:
            Text(model.fingerprint ?? "No fingerprint returned.").font(Typo.code).textSelection(.enabled)
                .padding(Metrics.gutter).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
            Text("Use Back to correct the address. Only trust a fingerprint you have verified.")
                .font(Typo.caption).foregroundStyle(.secondary)
        case .readyToInstall: installationSummary
        case .accounts: ServerSetupAccountsView(model: model)
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Loading projects and verifying the connection…") }
        case .complete:
            BloomServerIllustration(state: .complete, accent: Palette.controlAccent)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner * 2))
            Label("Your projects and conversations live on this server.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.controlAccent)
            Text("Agents can keep working when you close Bloom.").foregroundStyle(.secondary)
            Button("Start a Project…") {
                StartProjectOpening.shared.isRemote = true
                openWindow(id: StartProjectWindow.id)
                dismissWindow(id: windowID)
            }.buttonStyle(.link)
        }
    }

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("SSH address").font(Typo.labelEmphasis)
                TextField("SSH address", text: $model.host, prompt: Text("root@203.0.113.10"))
                    .labelsHidden().textFieldStyle(.roundedBorder).focused($addressIsFocused)
                    .accessibilityIdentifier("server-setup-address")
            }
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("Server label (optional)").font(Typo.labelEmphasis)
                TextField("Server label", text: $model.label, prompt: Text("For example, Development"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            DisclosureGroup("SSH key (optional)") {
                HStack {
                    TextField("Key file", text: $model.identityFile, prompt: Text("Use your SSH configuration or agent"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { showsKeyPicker = true }
                }
                Text("Leave empty for 1Password or your SSH agent. A selected key file is used directly.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                if let keySelectionFailure { Text(keySelectionFailure).font(Typo.caption).foregroundStyle(Palette.warning) }
            }
            if !hasConnectionNotice {
                Button("Connect to an existing Bloom server…", action: showAdvanced).buttonStyle(.link)
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var serverChecks: some View {
        if model.isBusy {
            HStack {
                ProgressView().controlSize(.small)
                Text(model.isStoppingServer ? "Stopping Bloom Server and checking the installation…" : "Checking SSH access, Ubuntu compatibility and installation…")
            }
                .font(Typo.caption).foregroundStyle(.secondary)
        } else if let check = model.check {
            ServerSetupCheckSummary(check: check, showAdvanced: showAdvanced,
                stopServer: model.canStopServer ? { confirmsStopServer = true } : nil)
        }
    }

    private var hasConnectionNotice: Bool {
        model.check?.blockers.contains { ["service_account_exists", "server_running", "server_busy"].contains($0.code) } == true
    }

    private var installationSummary: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter * 1.5) {
            ServerSetupInstallPlan(installationRoot: model.check?.installationRoot, serviceHome: model.check?.serviceHome, dataDirectory: model.check?.dataDirectory, alreadyInstalled: model.hasInstalledServer)
            if !model.hasInstalledServer {
                Divider()
                Text("Development tools").font(Typo.labelEmphasis)
                VStack(alignment: .leading, spacing: Metrics.gutter) {
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        HStack(spacing: Metrics.spacing) {
                            Toggle("Docker for container projects", isOn: $model.installsDocker).disabled(model.hasInstalledServer)
                            ServerSetupHelpButton(title: "Docker installation", details: dockerDetails)
                        }
                        Text("Run each project’s app and databases together. Starts automatically after a reboot.")
                            .font(Typo.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        HStack(spacing: Metrics.spacing) {
                            Toggle("Browser testing tools", isOn: $model.installsBrowserTools).disabled(model.hasInstalledServer)
                            ServerSetupHelpButton(title: "Browser testing tools", details: "Installs agent-browser, Chrome, browser libraries and fonts. May add a Chrome-specific AppArmor rule. Docker projects need their own browser setup. Website previews in Bloom work without these tools.")
                        }
                        Text("Let agents test websites with sandboxed Chrome.")
                            .font(Typo.caption).foregroundStyle(.secondary)
                    }
                    swapOption
                }
            }
            if model.hasInstalledServer {
                Label("Already installed. Continue to Accounts without reinstalling.", systemImage: "checkmark.circle.fill")
                    .font(Typo.caption).foregroundStyle(Palette.controlAccent)
            }
        }
    }

    private var dockerDetails: String {
        "Installs Ubuntu’s Docker, Compose and rootless networking packages. Docker runs as the Bloom account, without administrator access."
            + "\n\nRaises the server’s file-watch limit when needed, so development servers can watch large projects."
            + "\n\nImages and container data: " + (model.check?.serviceHome ?? "/home/bloom") + "/bloom/docker/data"
            + "\n\nThe user service and Docker connection settings use the account’s .config folder. Docker projects can run commands and access files as the Bloom account."
    }

    @ViewBuilder private var swapOption: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if model.check?.shouldOfferSwapInstall == true {
                HStack {
                    Toggle("Add 2 GB of swap", isOn: $model.installsSwap).disabled(model.hasInstalledServer)
                    ServerSetupHelpButton(title: "Swap space", details: "Swap uses disk space when memory is full. Bloom creates /var/lib/bloom/swapfile, protected by root, and enables it after reboots. Setup requires 4 GB free so at least 2 GB remains available. Existing swap is always preserved.")
                }
                Text("Helps keep the server responsive during memory spikes. Uses 2 GB of disk space.")
                    .font(Typo.caption).foregroundStyle(.secondary)
            } else if let bytes = model.check?.activeSwapBytes, bytes > 0 {
                Label("Swap is already active", systemImage: "checkmark.circle")
                    .font(Typo.label).foregroundStyle(Palette.controlAccent)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) + " of swap. Existing swap will be kept.")
                    .font(Typo.caption).foregroundStyle(.secondary)
            } else if model.check?.configuredSwap == true {
                Label("Existing swap configuration", systemImage: "internaldrive")
                    .font(Typo.label)
                Text("Swap is configured but not active. Bloom will keep your settings and will not add another swap file.")
                    .font(Typo.caption).foregroundStyle(.secondary)
            } else {
                Text("Swap could not be checked. Setup will leave it unchanged.")
                    .font(Typo.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if model.failure != nil && model.phase != .checking && model.phase != .address && model.phase != .trust {
            Button(model.phase == .installing ? "Check Again" : "Try Again") { Task { await model.retry() } }
                .keyboardShortcut(.defaultAction).disabled(model.isBusy)
        } else {
            switch model.phase {
            case .introduction: Button("Continue") { model.beginSetup() }.keyboardShortcut(.defaultAction)
            case .address, .checking:
                if model.canContinueToAccounts {
                    Button("Continue") { Task { await model.continueToAccounts() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.canReviewInstallation ? "Continue" : model.check != nil || model.failure != nil ? "Check Again" : "Check Server") {
                        if model.canReviewInstallation { model.reviewInstallation() } else { Task { await model.inspect() } }
                    }
                    .keyboardShortcut(.defaultAction).disabled(model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
            case .trust:
                Button("Trust and Continue") { Task { await model.trustHost() } }.keyboardShortcut(.defaultAction)
                    .disabled(model.fingerprint == nil || model.isBusy)
            case .readyToInstall:
                if model.canContinueToAccounts {
                    Button("Continue") { Task { await model.continueToAccounts() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Install") { Task { await model.install() } }.keyboardShortcut(.defaultAction)
                        .disabled(model.check == nil || model.check?.blockers.isEmpty == false || model.isBusy)
                }
            case .accounts:
                Button(model.hasChosenAccountMethod ? "Connect to Server" : "Sign In Separately") {
                    if model.hasChosenAccountMethod { Task { await model.connect() } } else { model.hasChosenAccountMethod = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || (model.hasChosenAccountMethod && !model.canConnect))
            case .complete:
                Button("Done") { dismissWindow(id: windowID) }.keyboardShortcut(.defaultAction)
            case .installing, .connecting: EmptyView()
            }
        }
    }

    private var setupStep: ServerSetupSteps.Step {
        switch model.phase {
        case .introduction: .introduction
        case .address, .trust, .checking: .server
        case .readyToInstall, .installing: .installation
        case .accounts, .connecting: .accounts
        case .complete: .finish
        }
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
