import Foundation
import BloomClient
import BloomAuthentication
import BloomSSH

/// Each window owns its selection and connection. The server owns workspaces and agent lifetime.
@MainActor
final class MobileConnection {
    static let drafts = ConversationDraftStore(file: URL.applicationSupportDirectory.appendingPathComponent("ConversationDrafts/drafts.json"))
    let authentication = ServerAuthentication()
    private(set) var address = UserDefaults.standard.string(forKey: "server.address") ?? ""
    private(set) var service: RemoteWorkspaceService?
    private(set) var catalogue: RemoteCatalogue?
    private(set) var isActive = true
    var changed: (() -> Void)?
    private var connection: HTTPSConnection?
    private var sshConnection: SSHConnection?
    private var sshConfiguration: SSHConfiguration?
    private var previewLeases: [UUID: MobilePreviewLease] = [:]
    private var terminals: [UUID: (WorkspaceID, String, any RemoteTerminalConnection)] = [:]
    private var generation = 0
    private var refreshTask: Task<Void, Never>?

    init() {}

    #if DEBUG
    init(previewCatalogue: RemoteCatalogue, client: any RemoteRequesting = PreviewRequestClient()) {
        catalogue = previewCatalogue
        address = "ssh://bloom@preview.bloom.invalid/var/lib/bloom"
        service = RemoteWorkspaceService(client: client)
    }
    #endif

    func connect(address: String) async throws {
        let origin = try HTTPSConnection.origin(address)
        disconnect()
        let generation = self.generation
        _ = try await authentication.token(for: origin.absoluteString)
        guard generation == self.generation else { throw CancellationError() }
        let authentication = authentication
        let connection = try HTTPSConnection(baseURL: origin) {
            try await authentication.token(for: origin.absoluteString)
        }
        let client = RemoteClient(connection: connection)
        do {
            let hello = try await client.request(.call("hello"))
            guard hello["hello"]?["name"]?.stringValue != nil else { throw ConnectionFailure("This is not a Bloom Server.") }
            let catalogue = try await RemoteCatalogue.decode(client.request(.call("catalogue")))
            guard generation == self.generation else { throw CancellationError() }
            self.connection = connection
            service = RemoteWorkspaceService(client: client)
            self.catalogue = catalogue
            self.address = origin.absoluteString
            UserDefaults.standard.set(self.address, forKey: "server.address")
            changed?()
        } catch { connection.close(); throw error }
    }

    func connect(ssh configuration: SSHConfiguration) async throws {
        disconnect()
        let generation = generation
        let connection = SSHConnection(configuration: configuration, privateKey: try SSHCredentials.identity(), fingerprint: try SSHCredentials.fingerprint(for: configuration.hostIdentity))
        do {
            let hello = try await connection.request(.call("hello"))
            guard hello["hello"]?["name"]?.stringValue != nil else { throw ConnectionFailure("This is not a Bloom Server.") }
            let catalogue = try await RemoteCatalogue.decode(connection.request(.call("catalogue")))
            guard generation == self.generation else { throw CancellationError() }
            sshConnection = connection
            sshConfiguration = configuration
            service = RemoteWorkspaceService(client: connection)
            self.catalogue = catalogue
            address = configuration.identity
            UserDefaults.standard.set(address, forKey: "server.address")
            UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: "server.ssh")
            changed?()
        } catch { await connection.close(); throw error }
    }

    func refresh() async throws {
        guard let service else { return }
        let generation = generation
        let catalogue = try await service.catalogue()
        guard generation == self.generation else { return }
        self.catalogue = catalogue
        changed?()
    }

    func disconnect() {
        generation += 1
        refreshTask?.cancel()
        connection?.close()
        connection = nil
        if let sshConnection { Task { await sshConnection.close() } }
        sshConnection = nil
        sshConfiguration = nil
        let leases = Array(previewLeases.values)
        previewLeases.removeAll()
        leases.forEach { $0.close() }
        let terminals = self.terminals.values.map { $0.2 }
        self.terminals.removeAll()
        Task { for terminal in terminals { await terminal.close() } }
        service = nil
        catalogue = nil
        changed?()
    }

    func openTerminal(workspaceID: WorkspaceID, name: String) async throws -> any RemoteTerminalConnection {
        guard let service else { throw ConnectionFailure("Reconnect to this server to open a terminal.") }
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ConnectionFailure("Use a valid terminal name.")
        }
        let generation = generation
        let remote: any RemoteTerminalConnection
        if let configuration = sshConfiguration {
            let result = try await service.client.request(.call("terminalStream", ["workspaceID": .string(workspaceID.rawValue), "name": .string(name)]))
            guard let path = result["text"]?["_0"]?.stringValue else { throw ConnectionFailure("The server did not open a terminal stream.") }
            guard let fingerprint = try SSHCredentials.fingerprint(for: configuration.hostIdentity) else { throw ConnectionFailure("Verify this server's SSH fingerprint before opening a terminal.") }
            remote = try await SSHTerminalConnection.open(configuration: configuration, privateKey: SSHCredentials.identity(), fingerprint: fingerprint, socketPath: path)
        } else if let connection {
            remote = try await HTTPSTerminalConnection.open(connection: connection, workspaceID: workspaceID.rawValue, name: name)
        } else { throw ConnectionFailure("This connection does not support interactive terminals.") }
        guard generation == self.generation, !Task.isCancelled else { await remote.close(); throw CancellationError() }
        let id = UUID()
        let managed = MobileTerminalLease(id: id, connection: remote) { [weak self] id in self?.terminals[id] = nil }
        terminals[id] = (workspaceID, name, managed)
        return managed
    }

    func closeTerminal(workspaceID: WorkspaceID, name: String) async throws {
        guard let service else { throw ConnectionFailure("Reconnect to this server to end a terminal.") }
        for (_, entry) in terminals where entry.0 == workspaceID && entry.1 == name { await entry.2.close() }
        _ = try await service.client.request(.call("workspace", ["workspaceID": .string(workspaceID.rawValue),
            "action": .object(["closeTerminal": .object(["name": .string(name)])])]))
    }

    /// Loopback addresses name the server's interface, never another device on its network.
    func preparePreview(address: String) async throws -> MobilePreviewLease {
        guard let service else { throw ConnectionFailure("Reconnect to this server to open a preview.") }
        let generation = generation
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = URL(string: trimmed), input.user == nil, input.password == nil,
              input.host?.isEmpty == false, ["http", "https"].contains(input.scheme?.lowercased() ?? "") else {
            throw ConnectionFailure("Enter the app's local HTTP address or an HTTPS preview address.")
        }
        if let configuration = sshConfiguration, Self.isLoopback(input) {
            guard input.scheme?.lowercased() == "http" else {
                throw ConnectionFailure("Use the app's local HTTP address for an SSH preview. Bloom encrypts the connection to your server.")
            }
            let remotePort = input.port ?? 80
            guard (1...65_535).contains(remotePort) else { throw ConnectionFailure("Enter a preview port between 1 and 65535.") }
            guard let fingerprint = try SSHCredentials.fingerprint(for: configuration.hostIdentity) else {
                throw ConnectionFailure("Reconnect and verify this server's SSH fingerprint before opening a preview.")
            }
            let tunnel = try await SSHPreviewTunnel.open(configuration: configuration,
                                                        privateKey: SSHCredentials.identity(),
                                                        fingerprint: fingerprint, remotePort: remotePort)
            guard generation == self.generation, !Task.isCancelled else {
                await tunnel.close()
                throw CancellationError()
            }
            guard var target = URLComponents(url: input, resolvingAgainstBaseURL: false) else {
                await tunnel.close()
                throw ConnectionFailure("This preview address is invalid.")
            }
            target.host = "127.0.0.1"
            target.port = tunnel.localPort
            guard let url = target.url else {
                await tunnel.close()
                throw ConnectionFailure("Could not create the local preview address.")
            }
            let lease = MobilePreviewLease(url: url, sourceURL: input, tunnel: tunnel)
            retain(lease)
            return lease
        }
        let reply = try await service.client.request(.call("previewAddress", ["_0": .string(trimmed)]))
        guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
        guard let resolved = reply["text"]?["_0"]?.stringValue, let url = URL(string: resolved),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, !Self.isLoopback(url) else {
            throw ConnectionFailure("Connect with SSH to preview the app's local port, or enter an HTTPS preview address.")
        }
        let lease = MobilePreviewLease(url: url)
        retain(lease)
        return lease
    }

    private func retain(_ lease: MobilePreviewLease) {
        previewLeases[lease.id] = lease
        lease.didClose = { [weak self] id in self?.previewLeases[id] = nil }
    }

    private static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    func suspend() { isActive = false; refreshTask?.cancel() }
    func resume() {
        isActive = true
        refreshTask?.cancel()
        refreshTask = Task { try? await refresh() }
    }
}

/// A browser owns one preview lease. Closing a tab or disconnecting revokes its local HTTP origin.
@MainActor
final class MobilePreviewLease {
    let id = UUID()
    let url: URL
    let sourceURL: URL
    private(set) var isClosed = false
    var onRevoked: (() -> Void)?
    fileprivate var didClose: ((UUID) -> Void)?
    private let tunnel: SSHPreviewTunnel?

    fileprivate init(url: URL, sourceURL: URL? = nil, tunnel: SSHPreviewTunnel? = nil) {
        self.url = url
        self.sourceURL = sourceURL ?? url
        self.tunnel = tunnel
    }

    var isTunnel: Bool { tunnel != nil }

    func allowsHTTP(_ target: URL) -> Bool {
        !isClosed && isTunnel && target.scheme?.lowercased() == "http" && target.host == "127.0.0.1"
            && target.port == url.port && target.user == nil && target.password == nil
    }

    func reportedURL(_ actual: URL) -> URL {
        guard allowsHTTP(actual), var components = URLComponents(url: actual, resolvingAgainstBaseURL: false) else { return actual }
        components.host = sourceURL.host
        components.port = sourceURL.port
        return components.url ?? sourceURL
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onRevoked?()
        onRevoked = nil
        if let tunnel { Task { await tunnel.close() } }
        didClose?(id)
        didClose = nil
    }

    deinit {
        if let tunnel { Task { await tunnel.close() } }
    }
}
