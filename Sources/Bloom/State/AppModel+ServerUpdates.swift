import Foundation

/// Server maintenance belongs to the app rather than to the Server Settings window.
///
/// The window used to own its maintenance model as view state, which meant update availability
/// existed only while Updates was open, and the sidebar had nothing to ask. One model, reached from
/// here by the sidebar and the window alike, keeps a single maintenance session per connection, so
/// a background check and an open review never hold two different answers.
extension AppModel {
    var serverMaintenance: ServerMaintenanceModel {
        if let serverMaintenanceStorage { return serverMaintenanceStorage }
        let model = ServerMaintenanceModel(server: remoteServer)
        serverMaintenanceStorage = model
        return model
    }

    func startServerUpdateChecks() {
        let maintenance = serverMaintenance
        Task { await maintenance.monitorUpdates() }
    }
}
