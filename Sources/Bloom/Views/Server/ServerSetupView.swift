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
    @State private var showsOutput = false
    @State private var copiedReport = false
    @FocusState private var addressIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                setupProgress
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(model.phase == .introduction ? Typo.displayHeading : Typo.heading)
                    Spacer()
                    if model.phase != .introduction && model.phase != .address && model.phase != .checking {
                        Text(model.label.isEmpty ? model.host : "\(model.label) · \(model.host)")
                            .font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(Typo.label).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Metrics.gutter * 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if model.phase == .introduction {
                    ServerSetupIntroduction(showAdvanced: showAdvanced)
                } else if model.phase == .installing || model.isInstallingBrowser {
                    ServerSetupActivityView(activity: model.activity, failure: model.failure ?? model.browserDiagnostic)
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

            Divider()
            HStack(spacing: Metrics.gutter) {
                Button(model.isStopping ? "Stopping…" : model.isBusy ? "Stop Setup" : "Cancel") {
                    if model.isBusy { Task { await model.stopSetup() } } else { model.cancel(); dismissWindow(id: windowID) }
                }
                .keyboardShortcut(.cancelAction).disabled(model.isStopping)
                if model.phase != .introduction {
                    Button("Back") { Task { await model.goBack() } }.disabled(!model.canGoBack)
                }
                if !model.activity.lines.isEmpty && model.phase != .installing && !model.isInstallingBrowser {
                    Button("View Output…") { showsOutput = true }.buttonStyle(.link)
                }
                if !model.activity.lines.isEmpty || model.failure != nil || model.check != nil {
                    Button(copiedReport ? "Copied" : "Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
                        copiedReport = true
                    }
                    .help("Copy the setup step, error and server output to share for troubleshooting.")
                }
                Spacer()
                primaryButton.buttonStyle(.borderedProminent).tint(Palette.controlAccent)
            }
            .padding(Metrics.gutter)
        }
        .frame(width: 800, height: 620)
        .sheet(isPresented: $showsOutput) {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                Text("Setup Output").font(Typo.heading)
                ServerSetupActivityView(activity: model.activity, failure: model.failure ?? model.browserDiagnostic)
                HStack { Spacer(); Button("Done") { showsOutput = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(Metrics.gutter * 2).frame(width: 800, height: 520)
        }
        .fileImporter(isPresented: $showsKeyPicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): model.identityFile = url.path; keySelectionFailure = nil
            case .failure: keySelectionFailure = "The key file could not be selected. Try again or enter its full path."
            }
        }
        .task { focusEmptyAddress(); if model.phase == .accounts { await model.refreshAccounts() } }
        .task(id: copiedReport) {
            guard copiedReport else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedReport = false
        }
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
        case .readyToInstall: model.hasInstalledServer ? "Server installed" : "Review installation"
        case .installing: model.failure == nil ? "Installing Bloom Server" : "Setup stopped"
        case .accounts: model.isInstallingBrowser ? "Installing browser tools" : "Connect your accounts"
        case .connecting: "Connecting to Bloom Server"
        case .complete: "Your server is ready"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .introduction: "Run projects on your server and pick up where you left off on any device."
        case .address, .checking: "Enter an Ubuntu server with administrator SSH access. This step only checks the server."
        case .trust: "Compare this fingerprint with your provider’s before trusting the connection."
        case .readyToInstall: model.hasInstalledServer ? "Your installation and sign-ins are preserved. Continue to finish connecting." : "Review the changes, then confirm to install."
        case .accounts: model.isInstallingBrowser ? "" : "Sign in for private repositories and agent chats. You can also do this later."
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
            Button("Connect to an existing Bloom server…", action: showAdvanced).buttonStyle(.link)
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var serverChecks: some View {
        if model.isBusy {
            HStack { ProgressView().controlSize(.small); Text("Checking SSH access, Ubuntu compatibility and installation…") }
                .font(Typo.caption).foregroundStyle(.secondary)
        } else if let check = model.check {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                HStack {
                    Label(check.blockers.isEmpty ? "Ready for setup" : "Setup needs attention",
                          systemImage: check.blockers.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(check.blockers.isEmpty ? Palette.controlAccent : Palette.warning)
                    Spacer()
                    Text("\(check.platform), \(check.architecture)").font(Typo.caption).foregroundStyle(.secondary)
                }
                ForEach(check.blockers, id: \.code) { notice in
                    ServerSetupNoticeView(notice: notice, serviceUser: check.serviceUser, showAdvanced: showAdvanced)
                }
                ForEach(check.warnings, id: \.code) { notice in
                    Text(notice.message).font(Typo.caption).foregroundStyle(.secondary)
                }
                if check.existing { Text("Existing Bloom installation found. Projects will be preserved.").font(Typo.caption).foregroundStyle(.secondary) }
            }
            .padding(Metrics.gutter)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        }
    }

    private var installationSummary: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter * 1.5) {
            ServerSetupInstallPlan(installationRoot: model.check?.installationRoot, serviceHome: model.check?.serviceHome, dataDirectory: model.check?.dataDirectory)
            Divider()
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Toggle("Add browser testing tools", isOn: $model.installsBrowserTools).disabled(model.hasInstalledServer)
                Text("Lets agents test websites with sandboxed Chrome. Website previews work without it.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                DisclosureGroup("Browser tool details") {
                    Text("Installs agent-browser, Chrome, browser libraries and fonts. May add a Chrome-specific AppArmor rule. Docker projects need their own browser setup.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                }
            }
            if model.hasInstalledServer {
                Label("Already installed. Continue to Accounts without reinstalling.", systemImage: "checkmark.circle.fill")
                    .font(Typo.caption).foregroundStyle(Palette.controlAccent)
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if model.failure != nil && model.phase != .checking && model.phase != .address && model.phase != .trust {
            Button(model.phase == .installing ? "Check Again" : "Try Again") { Task { await model.retry() } }
                .keyboardShortcut(.defaultAction).disabled(model.isBusy)
        } else {
            switch model.phase {
            case .introduction: Button("Get Started") { model.beginSetup() }.keyboardShortcut(.defaultAction)
            case .address, .checking:
                if model.canContinueToAccounts {
                    Button("Continue to Accounts") { Task { await model.continueToAccounts() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.canReviewInstallation ? "Review Installation…" : model.check != nil || model.failure != nil ? "Check Again" : "Check Server") {
                        if model.canReviewInstallation { model.reviewInstallation() } else { Task { await model.inspect() } }
                    }
                    .keyboardShortcut(.defaultAction).disabled(model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
            case .trust:
                Button("Trust and Continue") { Task { await model.trustHost() } }.keyboardShortcut(.defaultAction)
                    .disabled(model.fingerprint == nil || model.isBusy)
            case .readyToInstall:
                if model.canContinueToAccounts {
                    Button("Continue to Accounts") { Task { await model.continueToAccounts() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Confirm and Install") { Task { await model.install() } }.keyboardShortcut(.defaultAction)
                        .disabled(model.check == nil || model.check?.blockers.isEmpty == false || model.isBusy)
                }
            case .accounts:
                Button("Connect") { Task { await model.connect() } }.keyboardShortcut(.defaultAction).disabled(!model.canConnect || model.isBusy)
            case .complete:
                Button("Choose a Repository…") {
                    StartProjectOpening.shared.isRemote = true; openWindow(id: StartProjectWindow.id); dismissWindow(id: windowID)
                }.keyboardShortcut(.defaultAction)
            case .installing, .connecting: EmptyView()
            }
        }
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
            ForEach(Array(["Server", "Install", "Accounts"].enumerated()), id: \.offset) { index, name in
                if index > 0 { Image(systemName: "chevron.right").font(Typo.micro).foregroundStyle(Palette.textTertiary) }
                HStack(spacing: Metrics.spacingSmall) {
                    Image(systemName: index < setupStep ? "checkmark.circle.fill" : index == 0 ? "server.rack" : index == 1 ? "arrow.down.circle" : "person.crop.circle")
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffectsRemoved(reduceMotion)
                        .accessibilityHidden(true)
                    Text(name)
                }
                .font(Typo.captionEmphasis)
                .foregroundStyle(index <= setupStep ? Palette.controlAccent : Palette.textSecondary)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: setupStep)
        .accessibilityLabel(setupStep == 3 ? "Setup complete" : "Step \(setupStep + 1) of 3")
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
