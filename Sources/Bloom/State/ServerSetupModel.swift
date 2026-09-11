import Foundation
import Observation
import BloomCore
import BloomClient
import CryptoKit

@MainActor @Observable
final class ServerSetupModel {
    typealias InstallOperation = @Sendable (ServerSetupConnection, String, URL, URL, @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent
    enum Phase { case introduction, address, trust, checking, readyToInstall, installing, accounts, connecting, complete }
    var host = "" { didSet { if host != oldValue { connectionInputsChanged() } } }
    var identityFile = "" { didSet { if identityFile != oldValue { connectionInputsChanged() } } }
    var label = ""
    var installsBrowserTools = true
    var installsDocker = false
    private(set) var dockerReady = false
    private(set) var dockerAttempted = false
    private(set) var dockerDiagnostic: ServerSetupFailure?
    private(set) var isInstallingDocker = false
    var isInstallingOptionalTools: Bool { isInstallingBrowser || isInstallingDocker }
    var optionalDiagnostic: ServerSetupFailure? { dockerDiagnostic ?? browserDiagnostic }
    var hasChosenAccountMethod = false
    private(set) var browserReadiness: ServerBrowserReadiness?
    private(set) var browserFailure: String?
    private(set) var browserRecovery: String?
    private(set) var browserAttempted = false
    private(set) var browserDiagnostic: ServerSetupFailure?
    private(set) var phase = Phase.introduction
    private(set) var isBusy = false
    private(set) var isStopping = false
    private(set) var fingerprint: String?
    private(set) var failure: ServerSetupFailure?
    private(set) var progress: [String] = []
    private(set) var activity = ServerSetupActivity()
    private(set) var isInstallingBrowser = false
    private(set) var check: ServerInstallCheck?
    private(set) var accountChecks: [ServerDiagnostics.Check] = []
    private(set) var agentAuthentication: [AgentAuthenticationStatus] = []
    private let resources: URL?
    private let supportDirectory: URL?
    private let server: ServerWindowModel
    private let installConnection: InstallOperation
    private let inspectConnection: @Sendable (ServerSetupConnection, String) async throws -> ServerInstallCheck
    private var connection: ServerSetupConnection?
    private var candidate: ServerSetupHostKey?
    private var installed: ServerInstallEvent?
    private var clientKey: URL?
    private var installedKnownHosts: URL?
    private var task: Task<Void, Never>?
    private var stoppingServerID: UUID?
    private var generation = UUID()
    private var retryStep = Phase.address
    private var validatedHost = ""
    private var validatedIdentity = ""
    private var accountClient: ServerClient?

    var canInstallOptionalTools: Bool { connection != nil && installed?.serviceHome != nil && !isBusy }
    var githubIsAuthenticated: Bool { accountChecks.contains { $0.id == .github && $0.status == .ready } }
    var canConnect: Bool { installed != nil && accountClient != nil && !isBusy && !server.isConnecting && !server.isSigningIn && !server.isPerformingCommand }
    private var support: URL { supportDirectory ?? Store.defaultDirectory.appendingPathComponent("server-setup", isDirectory: true) }
    private var knownHosts: URL { support.appendingPathComponent("known_hosts") }

    init(server: ServerWindowModel, resources: URL? = nil, supportDirectory: URL? = nil, resumeExisting: Bool = true,
         inspectConnection: @escaping @Sendable (ServerSetupConnection, String) async throws -> ServerInstallCheck = { try await $0.inspect(script: $1) },
         installConnection: @escaping InstallOperation = { connection, script, archive, key, progress in
             try await connection.install(script: script, archive: archive, clientPublicKey: key, progress: progress)
         }) {
        self.resources = resources; self.supportDirectory = supportDirectory
        self.server = server
        self.inspectConnection = inspectConnection
        self.installConnection = installConnection
        if resumeExisting, server.isConfigured, !server.usesHTTPS, !server.knownHostsFile.isEmpty, !server.identityFile.isEmpty,
           let user = server.host.split(separator: "@").first, server.host.contains("@") {
            host = server.host; label = server.customLabel; validatedHost = server.host
            clientKey = URL(fileURLWithPath: server.identityFile)
            installedKnownHosts = URL(fileURLWithPath: server.knownHostsFile)
            installed = ServerInstallEvent(executable: server.executable, dataDirectory: server.remoteDirectory, serviceUser: String(user))
            phase = .accounts
            hasChosenAccountMethod = true
        }
    }

    func beginSetup() {
        guard phase == .introduction else { return }
        phase = .address
    }

    func showIntroduction() {
        guard phase == .address, !isBusy else { return }
        failure = nil
        phase = .introduction
    }

    func inspect() async {
        await perform(.checking) {
            self.hasChosenAccountMethod = false
            self.dockerReady = false; self.dockerAttempted = false; self.dockerDiagnostic = nil
            self.installed = nil; self.installedKnownHosts = nil; self.accountChecks = []; self.agentAuthentication = []; self.browserReadiness = nil; self.browserFailure = nil; self.browserRecovery = nil; self.browserAttempted = false; self.browserDiagnostic = nil; self.check = nil; self.candidate = nil; self.fingerprint = nil
            try self.prepareTrustStore()
            let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let connection = try ServerSetupConnection(host: host, identityFile: self.identityFile, knownHostsFile: self.knownHosts.path)
            self.connection = connection
            self.validatedHost = host; self.validatedIdentity = self.identityFile
            do {
                let check = try await self.inspectConnection(connection, self.installerScript())
                try Task.checkCancellation()
                self.check = check
                self.phase = .address
            } catch let error as ServerSetupFailure where error.code == .hostUnknown {
                let candidate = try await connection.candidateKey()
                try Task.checkCancellation()
                self.candidate = candidate; self.fingerprint = candidate.fingerprint; self.phase = .trust
            }
        }
    }

    func trustHost() async {
        guard let connection, let candidate, inputsUnchanged else { return }
        if await perform(.checking, operation: { try await connection.trust(candidate) }) { await inspect() }
    }

    var canReviewInstallation: Bool { check?.blockers.isEmpty == true && inputsUnchanged && !isBusy }
    var isStoppingServer: Bool { stoppingServerID != nil }

    var canStopServer: Bool {
        guard let check, check.existing, inputsUnchanged, !isBusy,
              check.blockers.contains(where: { $0.code == "server_running" }) else { return false }
        return check.blockers.allSatisfy { $0.code == "server_running" }
    }

    func stopServer() async {
        guard canStopServer, let connection else { return }
        let operationID = UUID()
        stoppingServerID = operationID
        defer { if stoppingServerID == operationID { stoppingServerID = nil } }
        await perform(.checking) {
            self.record("Checking for active work before stopping Bloom Server.")
            let check = try await connection.stopServer(script: self.installerScript())
            try Task.checkCancellation()
            self.check = check
            self.record("Bloom Server stopped. Installation checks refreshed.")
            self.phase = .address
        }
    }

    func reviewInstallation() {
        guard phase == .address, canReviewInstallation else { return }
        failure = nil
        phase = .readyToInstall
    }

    func install() async {
        guard phase == .readyToInstall, let connection, inputsUnchanged, check?.blockers.isEmpty == true else { return }
        activity.begin(browser: installsBrowserTools, docker: installsDocker)
        progress = []
        let completed = await perform(.installing) {
            let package = try self.serverPackage()
            let script = try self.installerScript()
            let key = try await self.prepareClientKey()
            self.clientKey = key
            self.record("Client key ready. Connecting to upload the server package.")
            let installed = try await self.installConnection(connection, script, package,
                URL(fileURLWithPath: key.path + ".pub")) { [weak self] event in
                    await self?.receive(event)
                }
            try Task.checkCancellation()
            self.installed = installed
            self.activity.finish()
            if self.installsBrowserTools { try await self.configureBrowser() }
            if self.installsDocker { try await self.configureDocker() }
            try Task.checkCancellation()
            self.phase = .accounts
        }
        if completed, installed != nil, phase == .accounts { await refreshAccounts() }
    }

    func refreshAccounts() async {
        guard let endpoint = installedEndpoint else { return }
        await perform(.accounts) {
            self.activity.start(.accounts, message: "Checking GitHub and agent sign-ins on the server")
            await self.accountClient?.disconnect()
            self.accountClient = nil
            let client = try await ServerClient.connect(to: endpoint)
            do {
                let reply = try await client.request(ServerRequest(.diagnostics), timeout: .seconds(20))
                guard case .diagnostics(let report) = reply.result else { throw ServerSetupFailure(code: .installation) }
                try Task.checkCancellation()
                self.accountClient = client
                self.accountChecks = report.checks
                self.agentAuthentication = report.authentication ?? []
                self.server.invalidateAgentAuthentication()
                self.browserReadiness = report.browser
                if report.browser?.status == .ready { self.browserFailure = nil; self.browserRecovery = nil; self.browserDiagnostic = nil }
                self.phase = .accounts
                self.activity.finish()
                self.record("Account checks complete.")
            } catch { await client.disconnect(); throw error }
        }
    }

    func retryBrowserInstall() async {
        guard canInstallOptionalTools else { return }
        let completed = await perform(.accounts) { try await self.configureBrowser() }
        if completed, phase == .accounts { await refreshAccounts() }
    }

    func retryDockerInstall() async {
        guard canInstallOptionalTools else { return }
        let completed = await perform(.accounts) { try await self.configureDocker() }
        if completed, phase == .accounts { await refreshAccounts() }
    }

    private func configureBrowser() async throws {
        browserAttempted = true; browserFailure = nil; browserRecovery = nil; browserDiagnostic = nil
        isInstallingBrowser = true
        defer { isInstallingBrowser = false }
        browserDiagnostic = try await configureOptionalTool(.browser, name: "Browser testing", scriptName: "install-bloom-browser.py") { connection, script, user, home, progress in
            try await connection.installBrowser(script: script, user: user, serviceHome: home, progress: progress)
        }
        browserFailure = browserDiagnostic?.message
        browserRecovery = browserDiagnostic?.recovery
    }

    private func configureDocker() async throws {
        dockerAttempted = true; dockerReady = false; dockerDiagnostic = nil
        isInstallingDocker = true
        defer { isInstallingDocker = false }
        dockerDiagnostic = try await configureOptionalTool(.docker, name: "Docker", scriptName: "install-bloom-docker.py") { connection, script, user, home, progress in
            try await connection.installDocker(script: script, user: user, serviceHome: home, progress: progress)
        }
        dockerReady = dockerDiagnostic == nil
    }

    /// Optional tools share the same streamed diagnostics and cancellation boundary. Their failure
    /// stays attached to the failed stage while the usable server continues to account setup.
    private func configureOptionalTool(
        _ stage: ServerSetupActivity.Stage, name: String, scriptName: String,
        operation: (ServerSetupConnection, String, String, String, @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent
    ) async throws -> ServerSetupFailure? {
        activity.start(stage, message: "Preparing " + name)
        do {
            guard let connection, let user = installed?.serviceUser, let home = installed?.serviceHome,
                  let url = resource(scriptName) else { throw ServerSetupFailure(code: .packageMissing) }
            let script = try String(contentsOf: url, encoding: .utf8)
            let result = try await operation(connection, script, user, home) { [weak self] event in await self?.receive(event) }
            try Task.checkCancellation()
            guard result.event == "complete", result.ready == true else {
                throw ServerSetupFailure.installation(code: result.code ?? "installation_failed", message: result.message,
                    recovery: result.recovery, details: result.details, command: result.command, exitStatus: result.exitStatus)
            }
            activity.finish()
            record(name + " verified on the server.")
            return nil
        } catch {
            try Task.checkCancellation()
            let diagnostic = error as? ServerSetupFailure ?? ServerSetupFailure(code: .unknown)
            activity.fail(message: diagnostic.message)
            record(diagnostic.message)
            if let command = diagnostic.command { activity.append("Command: " + command) }
            if let status = diagnostic.exitStatus { activity.append("Exit status: \(status)") }
            if let details = diagnostic.details, !activity.output.contains(details) { activity.append(details) }
            record("Bloom Server is ready. " + name + " needs attention.")
            return diagnostic
        }
    }

    func connect() async {
        guard canConnect, let installed, let endpoint = installedEndpoint,
              case .ssh(let host, let executable, let directory, let identity, let knownHosts) = endpoint else { return }
        await perform(.connecting) {
            self.record("Connecting to Bloom Server and loading its projects")
            await self.accountClient?.disconnect(); self.accountClient = nil
            try Task.checkCancellation()
            guard let profile = ServerConnectionProfile(values: [
                "host": host, "executable": executable, "directory": directory,
                "identityFile": identity ?? "", "knownHostsFile": knownHosts ?? "",
            ], label: self.label) else { throw ServerSetupFailure(code: .installation) }
            let connected = await self.server.connect(to: profile)
            try Task.checkCancellation()
            guard connected else { throw ServerSetupFailure(code: .unreachable) }
            if self.accountChecks.contains(where: { $0.id == .agents && $0.detail.contains("codex") }) { self.server.agent = .codex }
            self.record("Connected as \(installed.serviceUser ?? "bloom").")
            self.phase = .complete
        }
    }

    /// Credentials use the installed service account, never the administrator used for setup.
    var accountConnection: ServerSetupConnection? {
        guard let endpoint = installedEndpoint, case .ssh(let host, _, _, let identity, let knownHosts) = endpoint,
              let knownHosts else { return nil }
        return try? ServerSetupConnection(host: host, identityFile: identity, knownHostsFile: knownHosts)
    }

    func accountTerminal(_ account: ServerSetupAccount) -> TerminalLaunch? {
        guard let connection = accountConnection else { return nil }
        let command: String
        switch account {
        case .github: command = "GH_BROWSER=echo gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git"
        case .codex: command = "export PATH=\"$HOME/.local/bin:$PATH\"; if ! command -v codex >/dev/null; then npm install --global --prefix \"$HOME/.local\" @openai/codex || exit; fi; codex login --device-auth"
        case .claude: command = "export PATH=\"$HOME/.local/bin:$PATH\"; if ! command -v claude >/dev/null; then npm install --global --prefix \"$HOME/.local\" @anthropic-ai/claude-code || exit; fi; claude auth login"
        }
        guard var arguments = try? connection.arguments(command: command) else { return nil }
        if let index = arguments.firstIndex(of: "-T") { arguments[index] = "-tt" }
        return TerminalLaunch(executable: "/usr/bin/ssh", execName: "ssh", arguments: arguments,
                              environment: Shell.environment().map { "\($0.key)=\($0.value)" }.sorted(), directory: NSTemporaryDirectory())
    }

    func retry() async {
        switch retryStep {
        case .installing: await inspect()
        case .accounts: await refreshAccounts()
        case .connecting: await refreshAccounts(); if canConnect { await connect() }
        default: await inspect()
        }
    }

    var diagnosticReport: String {
        var parts = ["Bloom Server setup", "Server: \(host)", "Phase: \(phase)", "Step: \(activity.currentMessage)"]
        parts.append("Steps:\n" + ServerSetupActivity.Stage.allCases.map { "\($0.title): \(activity.status(of: $0))" }.joined(separator: "\n"))
        if let check {
            parts.append("System: \(check.platform), \(check.architecture), access: \(check.privilege)")
            for notice in check.blockers { parts.append("Check failed: \(notice.code)\n\(notice.message)\n\(notice.recoverySuggestion)") }
            for notice in check.warnings { parts.append("Warning: \(notice.message)") }
        }
        for failure in [failure, browserDiagnostic, dockerDiagnostic].compactMap({ $0 }) {
            parts += ["Error: \(failure.code.rawValue)", failure.message, "Recovery: \(failure.recovery)"]
            if let command = failure.command { parts.append("Command: " + command) }
            if let status = failure.exitStatus { parts.append("Exit status: \(status)") }
            if let details = failure.details { parts.append("Details:\n" + details) }
        }
        if let browserFailure { parts.append("Browser setup: " + browserFailure) }
        if let browserRecovery { parts.append("Browser recovery: " + browserRecovery) }
        if !activity.lines.isEmpty { parts.append("Server output:\n" + activity.output) }
        return parts.joined(separator: "\n\n")
    }

    var hasInstalledServer: Bool { installed != nil }
    var canContinueToAccounts: Bool { installedEndpoint != nil && inputsUnchanged && !isBusy }
    var canGoBack: Bool { phase != .introduction && (!isBusy || phase == .checking) }

    func goBack() async {
        guard canGoBack else { return }
        switch phase {
        case .introduction: break
        case .address: showIntroduction()
        case .trust, .checking, .readyToInstall: editAddress()
        case .installing:
            failure = nil
            phase = .readyToInstall
        case .accounts:
            failure = nil
            phase = check == nil ? .address : .readyToInstall
        case .connecting, .complete: await refreshAccounts()
        }
    }

    func continueToAccounts() async {
        guard canContinueToAccounts else { return }
        await refreshAccounts()
    }

    func editAddress() { cancel(); phase = .address; failure = nil }

    private func connectionInputsChanged() {
        guard phase != .introduction else { return }
        cancel()
        check = nil; candidate = nil; fingerprint = nil; failure = nil; progress = []
        installed = nil; connection = nil; activity = ServerSetupActivity()
        dockerReady = false; dockerAttempted = false; dockerDiagnostic = nil
        phase = .address
    }
    func stopSetup() async {
        guard isBusy, !isStopping else { return }
        let operation = task
        isStopping = true
        cancel()
        let stoppedGeneration = generation
        isBusy = true
        await operation?.value
        guard generation == stoppedGeneration else { isStopping = false; return }
        isBusy = false; isStopping = false
        failure = ServerSetupFailure(code: .cancelled)
        activity.fail(message: "Setup stopped by you")
        record("Setup stopped by you. The output is kept below.")
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false
        stoppingServerID = nil
        if let client = accountClient { Task { await client.disconnect() } }
        accountClient = nil
    }

    private var inputsUnchanged: Bool { host.trimmingCharacters(in: .whitespacesAndNewlines) == validatedHost && identityFile == validatedIdentity }
    private var installedEndpoint: ServerEndpoint? {
        guard let installed, let clientKey, let user = installed.serviceUser,
              let executable = installed.executable, let directory = installed.dataDirectory else { return nil }
        let address = validatedHost.split(separator: "@").last.map(String.init) ?? validatedHost
        return .ssh(host: user + "@" + address, executable: executable, directory: directory,
                    identityFile: clientKey.path, knownHostsFile: (installedKnownHosts ?? knownHosts).path)
    }

    @discardableResult
    private func perform(_ step: Phase, operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        let id = UUID(); generation = id; retryStep = step; phase = step; failure = nil; isBusy = true
        let task = Task { @MainActor in
            do { try await operation() } catch {
                guard self.generation == id else { return }
                let failure = error as? ServerSetupFailure ?? ServerSetupFailure(code: error is CancellationError ? .cancelled : .unknown)
                self.failure = failure
                self.activity.fail(message: failure.message)
                if self.activity.lines.last?.text != failure.message { self.record(failure.message) }
                if let command = failure.command { self.activity.append("Command: " + command) }
                if let status = failure.exitStatus { self.activity.append("Exit status: \(status)") }
                if let details = failure.details, !self.activity.output.contains(details) { self.activity.append(details) }
            }
            if self.generation == id { self.isBusy = false }
        }
        self.task = task
        await task.value
        return generation == id && failure == nil && !task.isCancelled
    }

    func receive(_ event: ServerInstallEvent) {
        guard !Task.isCancelled else { return }
        activity.receive(event)
        if event.event == "progress", let message = event.message {
            progress.append(String(message.prefix(300)))
            if progress.count > 50 { progress.removeFirst(progress.count - 50) }
        }
    }

    private func record(_ message: String) {
        guard !Task.isCancelled else { return }
        activity.append(message)
        progress.append(String(message.prefix(300)))
        if progress.count > 50 { progress.removeFirst(progress.count - 50) }
    }

    private func prepareTrustStore() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: knownHosts.path) {
            let original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
            let data = (try? Data(contentsOf: original)) ?? Data()
            try data.write(to: knownHosts, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
        }
    }

    private func prepareClientKey() async throws -> URL {
        let name = SHA256.hash(data: Data(validatedHost.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let path = support.appendingPathComponent("client-" + name)
        if !FileManager.default.fileExists(atPath: path.path) {
            let result = try await Shell.run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "Bloom server client", "-f", path.path], stdin: "", timeout: .seconds(10))
            guard result.ok else { throw ServerSetupFailure(code: .authentication) }
        }
        return path
    }

    private func resource(_ name: String) -> URL? {
        if let resources { return resources.appendingPathComponent(name) }
        return Bundle.main.resourceURL?.appendingPathComponent("ServerSetup").appendingPathComponent(name)
    }

    private func installerScript() throws -> String {
        guard let url = resource("install-bloom-server.py") else { throw ServerSetupFailure(code: .packageMissing) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func serverPackage() throws -> URL {
        guard let url = resource("server.tar.gz"),
              let metadata = resource("package.json"),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
              manifest["protocolVersion"] as? Int == ServerRequest.protocolVersion else { throw ServerSetupFailure(code: .packageMissing) }
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard manifest["sha256"] as? String == digest else { throw ServerSetupFailure(code: .packageInvalid) }
        return url
    }
}

enum ServerSetupAccount { case github, codex, claude }
