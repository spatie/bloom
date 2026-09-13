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
    enum AdministrationIntent { case start, update }
    private(set) var administration: ServerSetupModel?
    private(set) var administrationIntent = AdministrationIntent.start
    private var administrationProfile: String?
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
        let profileID = server.connectionProfile?.id
        var nextRetry = Date.distantPast
        while !Task.isCancelled, server.connectionProfile?.id == profileID {
            if server.isConnected {
                if generation != server.connectionGeneration || session == nil { await refresh() } else if session?.authorized == true { await session?.poll() }
            } else if administration?.isBusy != true, server.shouldReconnect, !server.isConnecting,
                      !server.isDisconnecting, server.isConfigured, Date() >= nextRetry {
                await server.connect(automatically: true)
                nextRetry = Date().addingTimeInterval(Double(max(2, server.connectionRecovery.retryDelaySeconds)))
            }
            let active = session?.jobs.contains(where: \.isActive) == true || session?.pendingMutationID != nil
            do { try await Task.sleep(for: .seconds(server.isConnected ? (active ? 2 : 10) : 1)) } catch { return }
        }
    }

    func reconnect() async {
        guard administration?.isBusy != true else { return }
        await server.connect()
        if server.isConnected { await refresh() }
    }

    func beginAdministration(_ intent: AdministrationIntent) {
        guard administration?.isBusy != true else { return }
        administration?.cancel()
        let setup = ServerSetupModel(server: server, resumeExisting: false)
        setup.label = server.displayName
        setup.installsBrowserTools = false; setup.installsDocker = false; setup.installsSwap = false
        if !server.usesHTTPS, let hostname = server.host.split(separator: "@").last {
            setup.host = "root@" + hostname
        }
        setup.beginSetup()
        administrationIntent = intent
        administrationProfile = server.connectionProfile?.id
        administration = setup
    }

    func performAdministration() async {
        guard let administration, server.connectionProfile?.id == administrationProfile else { return }
        switch administrationIntent {
        case .start: await administration.startExistingServer()
        case .update: await administration.updateExistingServer()
        }
        if server.isConnected { await refresh() }
    }

    func selectedServerChanged() {
        if administration?.isBusy != true { finishAdministration() }
    }

    func recoverAdministration() {
        guard administration?.isBusy != true else { return }
        administrationIntent = .start
    }

    func finishAdministration() {
        guard administration?.isBusy != true else { return }
        administration?.cancel()
        administration = nil
    }

    var report: String {
        ServerMaintenancePresentation.report(server: server.displayName,
            components: session?.components ?? [], jobs: session?.jobs ?? [], failure: session?.failure)
            + (administration.map { "\n\n" + $0.diagnosticReport } ?? "")
    }
}
