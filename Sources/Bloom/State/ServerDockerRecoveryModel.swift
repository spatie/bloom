import Foundation
import Observation
import BloomCore

/// The destination is captured when recovery opens. Switching the sidebar cannot retarget an
/// administrative command or rerun setup in a workspace on another server.
@MainActor @Observable
final class ServerDockerRecoveryModel {
    let request: ServerDockerRecoveryRequest
    var administratorHost: String
    var identityFile = ""
    private(set) var status: ServerDockerRecovery.Status?
    private(set) var failure: ServerSetupFailure?
    private(set) var activity = ServerSetupActivity()
    private(set) var isBusy = false
    private(set) var didRetryWorkspace = false
    private var task: Task<Void, Never>?
    private let server: ServerWindowModel

    init(request: ServerDockerRecoveryRequest, server: ServerWindowModel) {
        self.request = request; self.server = server
        administratorHost = "root@" + request.destination
    }

    var canRetryWorkspace: Bool {
        status?.state == .ready && !isBusy && !didRetryWorkspace && server.endpoint == request.endpoint && server.isConnected && workspace != nil
    }
    private var workspace: Workspace? {
        guard let id = request.workspaceID,
              let value = server.catalogue?.workspaces.first(where: { $0.id == id }),
              value.setupState != .running, !server.isRunning(value), !server.isAwaitingPermission(value) else { return nil }
        return value
    }
    private var connection: ServerSetupConnection {
        get throws { try ServerSetupConnection(host: request.host, identityFile: request.identityFile, knownHostsFile: request.knownHostsFile) }
    }

    func inspect() async {
        await perform("Checking Docker on " + request.host) {
            self.status = try await ServerDockerRecovery.inspect(using: self.connection)
            self.activity.append(self.status?.message ?? "Docker check complete.")
        }
    }

    func start() async {
        guard status?.state == .stopped else { return }
        await perform("Starting Docker for the Bloom account") {
            self.status = try await ServerDockerRecovery.start(using: self.connection)
            guard self.status?.state == .ready else {
                throw ServerSetupFailure.installation(code: "docker_start_failed", message: self.status?.message,
                    recovery: "Check the Docker user service output, then retry.", details: self.status?.details)
            }
            self.activity.append("Docker is ready. Existing containers and project data are preserved.")
        }
    }

    func install() async {
        guard let status, status.state == .needsSetup else { return }
        await perform("Setting up rootless Docker") {
            let host = self.administratorHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.split(separator: "@").last.map(String.init) == self.request.destination else {
                throw ServerSetupFailure.installation(code: "invalid_address", message: "Use an administrator account on " + self.request.destination + ".",
                    recovery: "Keep the same server address. Only the SSH user name and key may change.")
            }
            let administrator = try ServerSetupConnection(host: host, identityFile: self.identityFile, knownHostsFile: self.request.knownHostsFile)
            guard let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("ServerSetup/install-bloom-docker.py") else {
                throw ServerSetupFailure(code: .packageMissing)
            }
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            let result = try await administrator.installDocker(script: script, user: status.serviceUser, serviceHome: status.serviceHome) { [weak self] event in
                await self?.receive(event)
            }
            try Task.checkCancellation()
            guard result.event == "complete", result.ready == true else {
                throw ServerSetupFailure.installation(code: result.code ?? "docker_setup_failed", message: result.message,
                    recovery: result.recovery, details: result.details, command: result.command, exitStatus: result.exitStatus)
            }
            self.status = try await ServerDockerRecovery.inspect(using: self.connection)
            guard self.status?.state == .ready else {
                throw ServerSetupFailure.installation(code: "docker_setup_failed", message: self.status?.message,
                    recovery: "Docker is not yet available to the workspace account. Review the output and check again.", details: self.status?.details)
            }
        }
    }

    func retryWorkspace() async {
        guard canRetryWorkspace, let workspace else { return }
        await perform("Running the workspace setup again") {
            guard self.server.endpoint == self.request.endpoint, self.server.isConnected else {
                throw ServerSetupFailure.installation(code: "connection_changed", message: "Reconnect to the original server before running setup again.")
            }
            let result = await self.server.perform(.workspace(workspaceID: workspace.id, action: .runSetup))
            guard self.server.endpoint == self.request.endpoint else { return }
            guard result != nil else {
                throw ServerSetupFailure.installation(code: "setup_failed", message: self.server.error,
                    recovery: "Return to the workspace to review its setup output.")
            }
            self.didRetryWorkspace = true
            await self.server.refreshCatalogue()
        }
    }

    func cancel() { task?.cancel(); task = nil }

    private func receive(_ event: ServerInstallEvent) {
        guard !Task.isCancelled else { return }
        activity.receive(event)
    }

    private func perform(_ message: String, operation: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; failure = nil
        activity.start(.docker, message: message)
        let operationTask = Task { @MainActor in
            defer { self.isBusy = false }
            do {
                try await operation()
                try Task.checkCancellation()
                self.activity.finish()
            } catch {
                guard !Task.isCancelled else { self.activity.fail(message: "Docker recovery stopped"); return }
                let failure = error as? ServerSetupFailure ?? ServerSetupFailure.installation(code: "docker_recovery_failed",
                    message: error.localizedDescription, recovery: "Check the server connection and try again.")
                self.failure = failure
                self.activity.fail(message: failure.message)
                self.activity.append(failure.message)
                self.activity.append(failure.recovery)
                if let exitStatus = failure.exitStatus { self.activity.append("Exit status: \(exitStatus)") }
                if let command = failure.command { self.activity.append("Command: " + command) }
                if let details = failure.details { self.activity.append(details) }
            }
        }
        task = operationTask
        await operationTask.value
    }
}
