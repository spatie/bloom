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
    private var generation = 0
    private var refreshTask: Task<Void, Never>?

    init() {}

    #if DEBUG
    init(previewCatalogue: RemoteCatalogue) {
        catalogue = previewCatalogue
        address = "ssh://bloom@preview.bloom.invalid/var/lib/bloom"
        service = RemoteWorkspaceService(client: PreviewRequestClient())
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
        service = nil
        catalogue = nil
        changed?()
    }

    func suspend() { isActive = false; refreshTask?.cancel() }
    func resume() {
        isActive = true
        refreshTask?.cancel()
        refreshTask = Task { try? await refresh() }
    }
}
