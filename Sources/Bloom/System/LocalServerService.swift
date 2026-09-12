import Foundation
import ServiceManagement
import BloomCore

/// ServiceManagement owns the process lifetime. Connecting never replaces an existing service
/// or restarts its agents, including when its protocol version differs from this app's.
@MainActor
final class LocalServerService {
    private let bundle: Bundle
    private var service: SMAppService { .agent(plistName: LocalServerIdentity.plistName) }

    init(bundle: Bundle = .main) { self.bundle = bundle }

    var isRegistered: Bool { service.status == .enabled || service.status == .requiresApproval }

    func start() async throws -> ServerEndpoint {
        guard bundle.bundleURL.pathExtension == "app", let applicationID = bundle.bundleIdentifier else {
            throw ServerFailure("Run a built Bloom app to start its background server.")
        }
        let identity = try LocalServerIdentity(bundleID: applicationID)
        let executable = bundle.bundleURL.appendingPathComponent("Contents/MacOS/bloom-server")
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(LocalServerIdentity.plistName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: plist.path) else {
            throw ServerFailure("This app is missing its server component. Rebuild or reinstall Bloom.")
        }
        let service = service
        switch service.status {
        case .notRegistered: try service.register()
        case .enabled: break
        case .requiresApproval: throw LocalServerServiceError.requiresApproval
        case .notFound: throw ServerFailure("macOS could not find the local server. Rebuild or reinstall Bloom.")
        @unknown default: throw ServerFailure("macOS could not determine the local server's status.")
        }
        if service.status == .requiresApproval { throw LocalServerServiceError.requiresApproval }

        let endpoint = ServerEndpoint.local(directory: identity.directory())
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var lastError = "The local server has not started."
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if service.status == .requiresApproval { throw LocalServerServiceError.requiresApproval }
            do {
                let client = try await ServerClient.connect(to: endpoint, timeout: .seconds(2))
                await client.disconnect()
                return endpoint
            } catch {
                lastError = error.localizedDescription
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw ServerFailure("Could not connect to the local server. \(lastError)")
    }

    func stop() async throws { try await service.unregister() }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

enum LocalServerServiceError: Error, LocalizedError {
    case requiresApproval

    var errorDescription: String? {
        "Allow Bloom in System Settings > General > Login Items, then start the local server again."
    }
}
