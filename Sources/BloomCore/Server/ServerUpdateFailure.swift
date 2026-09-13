import Foundation

public struct ServerUpdateFailure: LocalizedError, Sendable {
    public let primaryFailure: String
    public let restartFailure: String?
    public let installationCompleted: Bool
    public let serverRunning: Bool

    public var errorDescription: String? {
        primaryFailure + "\n\n" + (restartFailure.map { "Bloom Server could not be restarted:\n" + $0 }
            ?? "Bloom Server is running again. Reconnect to continue using it.")
    }

    static func describe(_ error: any Error) -> String {
        let detail: String
        if error is CancellationError { detail = "The server update was cancelled." } else if let setup = error as? ServerSetupFailure {
            detail = [setup.message, setup.recovery, setup.details].compactMap { $0 }.joined(separator: "\n\n")
        } else { detail = error.localizedDescription }
        return ServerSetupDiagnostics.sanitise(detail)
    }
}
