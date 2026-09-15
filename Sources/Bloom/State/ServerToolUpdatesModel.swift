import Foundation
import Observation
import BloomCore

/// A confirmed update retains its original SSH connection when settings are closed. Results
/// are scoped to the reviewed server, and an interrupted update is never retried automatically.
@MainActor @Observable
final class ServerToolUpdatesModel {
    struct Review: Identifiable {
        let id = UUID()
        let tool: ServerToolUpdates.Tool
        let serverName: String
        let generation: Int
    }

    let server: ServerWindowModel
    private(set) var installations: [ServerToolUpdates.Installation] = []
    private(set) var isLoading = false
    private(set) var updating: ServerToolUpdates.Tool?
    private(set) var failure: String?
    private(set) var result: String?
    private(set) var activity = ServerSetupActivity()
    private var generation: Int?
    private var requestID = UUID()

    init(server: ServerWindowModel) { self.server = server }

    var connection: ServerSetupConnection? {
        guard server.isConnected, !server.usesHTTPS,
              case .ssh(let host, _, _, let identity, let knownHosts) = server.endpoint,
              let knownHosts, !knownHosts.isEmpty else { return nil }
        return try? ServerSetupConnection(host: host, identityFile: identity, knownHostsFile: knownHosts)
    }

    var canUpdate: Bool {
        connection != nil && !isLoading && updating == nil && !server.isPerformingCommand
            && !server.isConnecting && generation == server.connectionGeneration && failure == nil
    }

    func refresh() async {
        guard updating == nil else { return }
        let current = server.connectionGeneration
        if generation != current { installations = []; result = nil; activity = ServerSetupActivity() }
        guard let connection else { isLoading = false; return }
        let id = UUID(); requestID = id
        isLoading = true; failure = nil
        defer { if requestID == id { isLoading = false } }
        do {
            let values = try await ServerToolUpdates.inspect(connection: connection)
            try Task.checkCancellation()
            guard requestID == id, current == server.connectionGeneration else { return }
            installations = values; generation = current
        } catch is CancellationError {
            // Navigation owns inspection. It does not own an explicitly confirmed update.
        } catch {
            guard requestID == id, current == server.connectionGeneration else { return }
            failure = ServerSetupDiagnostics.sanitise(error.localizedDescription)
        }
    }

    func review(_ tool: ServerToolUpdates.Tool) -> Review? {
        guard canUpdate, installations.contains(where: { $0.tool == tool && $0.canUpdate }) else { return nil }
        return Review(tool: tool, serverName: server.displayName, generation: server.connectionGeneration)
    }

    func update(_ review: Review) async {
        guard canUpdate, review.generation == server.connectionGeneration, let connection else { return }
        updating = review.tool; result = nil; failure = nil; activity = ServerSetupActivity()
        activity.append("Server: " + review.serverName)
        do {
            let completed = try await ServerToolUpdates.update(review.tool, connection: connection) { [weak self] event in
                await self?.receive(event, generation: review.generation)
            }
            if review.generation == server.connectionGeneration { result = completed.message }
        } catch {
            if review.generation == server.connectionGeneration {
                let detail: String
                if let setup = error as? ServerSetupFailure {
                    detail = [setup.message, setup.recovery, setup.details].compactMap { $0 }.joined(separator: "\n\n")
                } else { detail = error.localizedDescription }
                failure = ServerSetupDiagnostics.sanitise(detail)
                activity.append(failure ?? "Update was not confirmed.")
            }
        }
        updating = nil
        let updateFailure = failure
        await refresh()
        if review.generation == server.connectionGeneration, let updateFailure { failure = updateFailure }
    }

    private func receive(_ event: ServerInstallEvent, generation: Int) {
        guard generation == server.connectionGeneration else { return }
        activity.receive(event)
    }

    var diagnosticReport: String {
        let versions = installations.map { $0.tool.title + ": " + ($0.version ?? $0.detail) }.joined(separator: "\n")
        return ServerSetupDiagnostics.sanitise(["Bloom Server tool updates", server.displayName, versions,
            activity.output, failure, result].compactMap { $0 }.joined(separator: "\n\n"))
    }
}
