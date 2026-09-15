import Foundation
import BloomCore
import BloomClient

/// Update availability, read in the background while the Updates screen is closed.
///
/// Updates used to be visible only to somebody who opened Server Settings > Updates, so a server
/// could sit several releases behind with nothing in the window saying so. This loop asks the
/// same supervisor `inspect` the screen does, on the schedule `ServerUpdateCheckSchedule` decides,
/// and never prepares or starts anything: installing stays a reviewed action.
extension ServerMaintenanceModel {
    /// What the sidebar and Server Settings show. Nil while disconnected, so a stale answer from
    /// an earlier connection never advertises an update for a server that is not there.
    var updateNotice: ServerUpdateNotice? {
        guard server.isConnected, generation == server.connectionGeneration else { return nil }
        return session?.updateNotice
    }

    /// Runs for the life of the app. A second caller returns at once rather than doubling checks.
    func monitorUpdates() async {
        guard !isMonitoringUpdates else { return }
        isMonitoringUpdates = true
        defer { isMonitoringUpdates = false }
        while !Task.isCancelled {
            await checkForUpdatesIfDue()
            // A minute bounds how long a fresh connection waits for its first check; the schedule
            // itself keeps the checks hours apart.
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }

    func checkForUpdatesIfDue(now: Date = Date()) async {
        let scope = ServerUpdateCheckSchedule.scope(serverID: server.connectionProfile?.id, connectionGeneration: server.connectionGeneration)
        guard updateChecks.isDue(scope: scope, connected: server.isConnected, busy: isBusyForUpdateCheck, now: now), let scope else { return }
        await refresh()
        let outcome: ServerUpdateCheckSchedule.Outcome = session.map {
            .outcome(authorized: $0.authorized, capability: $0.capability, failure: $0.failure)
        } ?? .failed
        updateChecks.record(outcome, scope: scope, at: Date())
    }

    private var isBusyForUpdateCheck: Bool {
        server.isConnecting || server.isMaintainingServer || administrationIsRunning || administration?.isBusy == true
            || (session.map { $0.activity != .idle || $0.pendingMutationID != nil } ?? false)
    }
}
