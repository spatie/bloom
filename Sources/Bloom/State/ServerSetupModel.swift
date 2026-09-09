import Foundation
import Observation
import BloomCore
import CryptoKit

@MainActor @Observable
final class ServerSetupModel {
    enum Phase { case address, trust, checking, readyToInstall, installing, accounts, connecting, complete }
    var host = ""
    var identityFile = ""
    var label = ""
    private(set) var phase = Phase.address
    private(set) var isBusy = false
    private(set) var fingerprint: String?
    private(set) var failure: ServerSetupFailure?
    private(set) var progress: [String] = []
    private(set) var check: ServerInstallCheck?
    private(set) var accountChecks: [ServerDiagnostics.Check] = []
    private let server: ServerWindowModel
    private unowned let app: AppModel
    private var connection: ServerSetupConnection?
    private var candidate: ServerSetupHostKey?
    private var installed: ServerInstallEvent?
    private var clientKey: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var retryStep = Phase.address
    private var validatedHost = ""
    private var validatedIdentity = ""
    private var accountClient: ServerClient?

    var canConnect: Bool { installed != nil && accountClient != nil && !isBusy }
    private var support: URL { Store.defaultDirectory.appendingPathComponent("server-setup", isDirectory: true) }
    private var knownHosts: URL { support.appendingPathComponent("known_hosts") }

    init(server: ServerWindowModel, app: AppModel) {
        self.server = server
        self.app = app
        if server.isConfigured, !server.usesHTTPS, !server.knownHostsFile.isEmpty, !server.identityFile.isEmpty,
           let user = server.host.split(separator: "@").first, server.host.contains("@") {
            host = server.host; label = server.customLabel; validatedHost = server.host
            clientKey = URL(fileURLWithPath: server.identityFile)
            installed = ServerInstallEvent(executable: server.executable, dataDirectory: server.remoteDirectory, serviceUser: String(user))
            phase = .accounts
        }
    }

    func inspect() async {
        await perform(.checking) {
            self.installed = nil; self.accountChecks = []; self.check = nil; self.candidate = nil; self.fingerprint = nil
            try self.prepareTrustStore()
            let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let connection = try ServerSetupConnection(host: host, identityFile: self.identityFile, knownHostsFile: self.knownHosts.path)
            self.connection = connection
            self.validatedHost = host; self.validatedIdentity = self.identityFile
            do {
                let check = try await connection.inspect(script: self.installerScript())
                try Task.checkCancellation()
                self.check = check
                self.phase = .readyToInstall
            } catch let error as ServerSetupFailure where error.code == .hostUnknown {
                let candidate = try await connection.candidateKey()
                try Task.checkCancellation()
                self.candidate = candidate; self.fingerprint = candidate.fingerprint; self.phase = .trust
            }
        }
    }

    func trustHost() async {
        guard let connection, let candidate, inputsUnchanged else { return }
        await perform(.checking) { try await connection.trust(candidate) }
        if failure == nil { await inspect() }
    }

    func install() async {
        guard let connection, inputsUnchanged, check?.blockers.isEmpty == true else { return }
        await perform(.installing) {
            let package = try self.serverPackage()
            let script = try self.installerScript()
            let key = try await self.prepareClientKey()
            self.clientKey = key
            self.progress.append("Uploading the server package…")
            let installed = try await connection.install(script: script, archive: package,
                clientPublicKey: URL(fileURLWithPath: key.path + ".pub")) { [weak self] event in
                    guard let message = event.message, event.event == "progress" else { return }
                    await self?.record(message)
                }
            try Task.checkCancellation()
            self.installed = installed
            self.phase = .accounts
        }
        if installed != nil, failure == nil { await refreshAccounts() }
    }

    func refreshAccounts() async {
        guard let endpoint = installedEndpoint else { return }
        await perform(.accounts) {
            await self.accountClient?.disconnect()
            self.accountClient = nil
            let client = try await ServerClient.connect(to: endpoint)
            do {
                let reply = try await client.request(ServerRequest(.diagnostics), timeout: .seconds(20))
                guard case .diagnostics(let report) = reply.result else { throw ServerSetupFailure(code: .installation) }
                try Task.checkCancellation()
                self.accountClient = client
                self.accountChecks = report.checks
                self.phase = .accounts
            } catch { await client.disconnect(); throw error }
        }
    }

    func connect() async {
        guard canConnect, let installed, let endpoint = installedEndpoint,
              case .ssh(let host, let executable, let directory, let identity, let knownHosts) = endpoint else { return }
        await perform(.connecting) {
            await self.accountClient?.disconnect(); self.accountClient = nil
            self.server.host = host
            self.server.executable = executable
            self.server.remoteDirectory = directory
            self.server.identityFile = identity ?? ""
            self.server.knownHostsFile = knownHosts ?? ""
            self.server.usesHTTPS = false
            self.server.connectionMode = .remote
            self.server.renameServer(self.label)
            await self.server.connect()
            guard self.server.isConnected else { throw ServerSetupFailure(code: .unreachable) }
            if self.accountChecks.contains(where: { $0.id == .agents && $0.detail.contains("codex") }) { self.server.agent = .codex }
            self.progress.append("Connected as \(installed.serviceUser ?? "bloom").")
            self.phase = .complete
        }
    }

    func accountTerminal(_ account: ServerSetupAccount) -> TerminalLaunch? {
        guard let endpoint = installedEndpoint, case .ssh(let host, _, _, let identity, let knownHosts) = endpoint,
              let knownHosts, let connection = try? ServerSetupConnection(host: host, identityFile: identity, knownHostsFile: knownHosts) else { return nil }
        let command: String
        switch account {
        case .github: command = "gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git"
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
        case .installing: await install()
        case .accounts: await refreshAccounts()
        case .connecting: await refreshAccounts(); if canConnect { await connect() }
        default: await inspect()
        }
    }

    func editAddress() { cancel(); phase = .address; failure = nil; installed = nil; check = nil }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false
        if let client = accountClient { Task { await client.disconnect() } }
        accountClient = nil
    }

    private var inputsUnchanged: Bool { host.trimmingCharacters(in: .whitespacesAndNewlines) == validatedHost && identityFile == validatedIdentity }
    private var installedEndpoint: ServerEndpoint? {
        guard let installed, let clientKey, let user = installed.serviceUser,
              let executable = installed.executable, let directory = installed.dataDirectory else { return nil }
        let address = validatedHost.split(separator: "@").last.map(String.init) ?? validatedHost
        return .ssh(host: user + "@" + address, executable: executable, directory: directory,
                    identityFile: clientKey.path, knownHostsFile: knownHosts.path)
    }

    private func perform(_ step: Phase, operation: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        let id = UUID(); generation = id; retryStep = step; phase = step; failure = nil; isBusy = true
        let task = Task { @MainActor in
            do { try await operation() } catch {
                guard self.generation == id else { return }
                self.failure = error as? ServerSetupFailure ?? ServerSetupFailure(code: error is CancellationError ? .cancelled : .unknown)
            }
            if self.generation == id { self.isBusy = false }
        }
        self.task = task
        await task.value
    }

    private func record(_ message: String) {
        guard !Task.isCancelled else { return }
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

    private func installerScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "install-bloom-server", withExtension: "py", subdirectory: "ServerSetup") else { throw ServerSetupFailure(code: .packageMissing) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func serverPackage() throws -> URL {
        guard let url = Bundle.main.url(forResource: "server", withExtension: "tar.gz", subdirectory: "ServerSetup"),
              let metadata = Bundle.main.url(forResource: "package", withExtension: "json", subdirectory: "ServerSetup"),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
              manifest["protocolVersion"] as? Int == ServerRequest.protocolVersion else { throw ServerSetupFailure(code: .packageMissing) }
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard manifest["sha256"] as? String == digest else { throw ServerSetupFailure(code: .packageInvalid) }
        return url
    }
}

enum ServerSetupAccount { case github, codex, claude }
