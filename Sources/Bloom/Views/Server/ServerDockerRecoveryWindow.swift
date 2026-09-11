import SwiftUI
import BloomCore

/// Only public connection metadata is carried in the window route. Credentials remain in their
/// existing key files, and each operation retains the original server's host-key pin.
struct ServerDockerRecoveryRequest: Hashable, Codable {
    let host: String
    let executable: String
    let directory: String
    let identityFile: String?
    let knownHostsFile: String
    let label: String
    let workspaceID: WorkspaceID?

    @MainActor init?(server: ServerWindowModel, workspaceID: WorkspaceID? = nil) {
        guard case .ssh(let host, let executable, let directory, let identity, let knownHosts) = server.endpoint,
              let knownHosts, !knownHosts.isEmpty else { return nil }
        self.host = host; self.executable = executable; self.directory = directory
        identityFile = identity; knownHostsFile = knownHosts; label = server.displayName; self.workspaceID = workspaceID
    }
    var destination: String { host.split(separator: "@").last.map(String.init) ?? host }
    var endpoint: ServerEndpoint { .ssh(host: host, executable: executable, directory: directory, identityFile: identityFile, knownHostsFile: knownHostsFile) }
}

struct ServerDockerRecoveryWindow: Scene {
    static let id = "bloom-server-docker"
    let model: AppModel

    var body: some Scene {
        WindowGroup("Docker on Server", id: Self.id, for: ServerDockerRecoveryRequest.self) { $request in
            if let request {
                ServerDockerRecoveryContent(request: request, server: model.remoteServer)
                    .environment(model).windowRole(.utility)
            }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

private struct ServerDockerRecoveryContent: View {
    @State private var model: ServerDockerRecoveryModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsOutput = false
    @FocusState private var administratorFocused: Bool

    init(request: ServerDockerRecoveryRequest, server: ServerWindowModel) {
        _model = State(initialValue: ServerDockerRecoveryModel(request: request, server: server))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Docker on " + model.request.label).font(Typo.heading)
            Text("Containers run as the Bloom account on \(model.request.host). Your current workspace stays open.")
                .font(Typo.caption).foregroundStyle(.secondary)
            if model.isBusy {
                ServerSetupActivityView(activity: model.activity, failure: model.failure, compact: true, stages: [.docker])
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.gutter) {
                        if let failure = model.failure { ServerSetupFailureView(failure: failure) }
                        if let status = model.status {
                            Label(status.message, systemImage: status.state == .ready ? "checkmark.circle" : "shippingbox")
                                .font(Typo.labelEmphasis).textSelection(.enabled)
                            if status.state == .needsSetup { installationForm(home: status.serviceHome) }
                            if status.state == .stopped {
                                Text("Start the existing Docker user service. This does not install packages or require administrator access.")
                                    .font(Typo.caption).foregroundStyle(.secondary)
                            }
                            if model.didRetryWorkspace { Text("Setup has been requested. Follow its progress in the workspace.").font(Typo.caption) }
                            if status.state == .ready, model.request.workspaceID != nil, !model.canRetryWorkspace, !model.didRetryWorkspace {
                                Text("Return to this server and wait for any active workspace tasks to finish before running setup again.")
                                    .font(Typo.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button(model.isBusy ? "Stop" : "Close") { model.cancel(); if !model.isBusy { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                if !model.activity.lines.isEmpty { Button("View Output…") { showsOutput = true } }
                Spacer()
                if !model.isBusy {
                    Button("Check Again") { Task { await model.inspect() } }
                    if model.status?.state == .stopped {
                        Button("Start Docker") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                    } else if model.status?.state == .needsSetup {
                        Button("Set Up Docker") { Task { await model.install() } }.buttonStyle(.borderedProminent)
                    } else if model.canRetryWorkspace {
                        Button("Run Setup Again") { Task { await model.retryWorkspace() } }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(Metrics.gutter * 2).frame(width: 720, height: 580)
        .tint(Palette.controlAccent)
        .task { await model.inspect() }
        .onDisappear { model.cancel() }
        .onChange(of: model.status?.state) { _, state in administratorFocused = state == .needsSetup }
        .sheet(isPresented: $showsOutput) {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                ServerSetupActivityView(activity: model.activity, failure: model.failure, compact: true, stages: [.docker])
                HStack { Spacer(); Button("Done") { showsOutput = false }.keyboardShortcut(.cancelAction) }
            }.padding(Metrics.gutter * 2).frame(width: 720, height: 520)
        }
    }

    private func installationForm(home: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Set up Docker for container projects").font(Typo.labelEmphasis)
            Text("Installs Ubuntu's Docker, Compose and rootless networking packages. Docker runs as the Bloom account and starts after a reboot. It does not receive administrator access or access to the system Docker socket.")
                .font(Typo.caption).foregroundStyle(.secondary)
            Text("Images and container data: " + home + "/bloom/docker/data\nUser service and connection settings: " + home + "/.config")
                .font(Typo.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("Administrator SSH address", text: $model.administratorHost, prompt: Text("root@" + model.request.destination))
                .textFieldStyle(.roundedBorder).focused($administratorFocused)
            TextField("SSH key file (optional)", text: $model.identityFile, prompt: Text("Use your SSH agent or 1Password"))
                .textFieldStyle(.roundedBorder)
            Text("Administrator access is used only for installation. Bloom verifies the same trusted server identity. Your existing server and workspaces are preserved.")
                .font(Typo.caption).foregroundStyle(.secondary)
        }
    }
}
