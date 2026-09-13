import Foundation

/// A completed installer is distinct from a healthy service and a restored client connection.
public enum ServerAdministrationOutcome: Sendable, Equatable {
    case updated, started, updatedNeedsConnection, updateFailedServerRunning, needsAttention

    public static func resolve(updating: Bool, installed: Bool, running: Bool, connected: Bool, failed: Bool) -> Self {
        if updating {
            if installed { return running && connected && !failed ? .updated : .updatedNeedsConnection }
            return running ? .updateFailedServerRunning : .needsAttention
        }
        return running && connected && !failed ? .started : .needsAttention
    }

    public var title: String {
        switch self {
        case .updated: "Server updated"
        case .started: "Server started"
        case .updatedNeedsConnection: "Installed, connection needs attention"
        case .updateFailedServerRunning: "Update did not finish. Server is running"
        case .needsAttention: "Server needs attention"
        }
    }

    public var detail: String {
        switch self {
        case .updated: "Bloom Server is running and this Mac is connected. Your workspaces are ready."
        case .started: "This Mac is connected to the existing installation. No packages were replaced."
        case .updatedNeedsConnection: "The package was installed, but startup or reconnection could not be confirmed. Check the connection before trying another update."
        case .updateFailedServerRunning: "Bloom restored the service. Review the error and output before trying the update again."
        case .needsAttention: "The operation did not finish successfully. Review the error and output below."
        }
    }

    public var succeeded: Bool { self == .updated || self == .started }
}
