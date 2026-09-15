import Observation

/// Server Settings is a single window scene, so the sidebar cannot hand it an argument. A menu
/// command sets this before opening the window, and the window consumes it whether it was
/// already open or appears because of the request.
@MainActor
@Observable
final class ServerSettingsOpening {
    static let shared = ServerSettingsOpening()
    var requestsUninstall = false
}
