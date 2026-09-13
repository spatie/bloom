import Foundation

/// Installation owns its rollback. This outer lifecycle ensures a stopped service is offered
/// a fresh start even when SSH loses the stop/install acknowledgement or the caller cancels.
public enum ServerUpdateLifecycle {
    public static func perform(
        needsStop: Bool,
        stop: @escaping @Sendable () async throws -> Void,
        install: @escaping @Sendable () async throws -> ServerInstallEvent,
        restart: @escaping @Sendable () async throws -> Void
    ) async throws -> ServerInstallEvent {
        try Task.checkCancellation()
        let installed: ServerInstallEvent
        do {
            if needsStop { try await stop() }
            try Task.checkCancellation()
            installed = try await install()
        } catch {
            let primary = ServerUpdateFailure.describe(error)
            let recovery = await Task.detached { () -> String? in
                do { try await restart(); return nil } catch { return ServerUpdateFailure.describe(error) }
            }.value
            throw ServerUpdateFailure(primaryFailure: primary, restartFailure: recovery,
                                      installationCompleted: false, serverRunning: recovery == nil)
        }
        // A successful installer already starts the unit. This idempotent call also verifies
        // readiness, and runs outside the cancelled UI task before it hands connection back.
        let recovery = await Task.detached { () -> String? in
            do { try await restart(); return nil } catch { return ServerUpdateFailure.describe(error) }
        }.value
        if let recovery {
            throw ServerUpdateFailure(primaryFailure: "The installation completed, but startup could not be confirmed.",
                                      restartFailure: recovery, installationCompleted: true, serverRunning: false)
        }
        return installed
    }
}
