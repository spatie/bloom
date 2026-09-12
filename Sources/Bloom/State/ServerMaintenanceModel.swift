import Foundation
import Observation
import BloomCore
import BloomClient
import BloomAuthentication

/// The window owns observation, while the supervisor owns maintenance execution. A connection
/// change replaces the client and credential scope instead of carrying a review to another host.
@MainActor @Observable
final class ServerMaintenanceModel {
    let server: ServerWindowModel
    private(set) var access: ServerMaintenanceAccess?
    private var generation: Int?
    var session: ServerMaintenanceSession? { access?.session }

    init(server: ServerWindowModel) { self.server = server }

    func refresh() async {
        guard server.isConnected, let serverID = server.connectionProfile?.id,
              let service = server.maintenanceService() else { access = nil; generation = nil; return }
        if generation != server.connectionGeneration || access?.serverID != serverID {
            access = ServerMaintenanceAccess(serverID: serverID, client: service.client)
            generation = server.connectionGeneration
        }
        await access?.refresh()
    }

    func observe() async {
        await refresh()
        let expected = generation
        while !Task.isCancelled, server.isConnected, expected == server.connectionGeneration, let session {
            let active = session.jobs.contains(where: \.isActive) || session.pendingMutationID != nil
            do { try await Task.sleep(for: .seconds(active ? 2 : 10)) } catch { return }
            guard !Task.isCancelled, expected == server.connectionGeneration else { return }
            if session.authorized { await session.poll() }
        }
    }

    var report: String {
        ServerMaintenancePresentation.report(server: server.displayName,
            components: session?.components ?? [], jobs: session?.jobs ?? [], failure: session?.failure)
    }
}
