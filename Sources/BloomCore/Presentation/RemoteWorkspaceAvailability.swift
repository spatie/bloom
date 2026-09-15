/// What can be shown before a selected server workspace has a usable pane model.
public enum RemoteWorkspaceAvailability: Equatable, Sendable {
    case ready, opening, connecting, disconnected, unconfigured, empty, missing

    public static func resolve(
        hasWorkspace: Bool, hasModel: Bool, isConfigured: Bool,
        isConnected: Bool, isConnecting: Bool, hasCatalogue: Bool, workspaceCount: Int
    ) -> Self {
        // A transport interruption must not hide a readable cached workspace.
        if hasWorkspace { return hasModel ? .ready : .opening }
        if isConnecting { return .connecting }
        if !isConfigured { return .unconfigured }
        if !isConnected { return .disconnected }
        if !hasCatalogue { return .connecting }
        return workspaceCount == 0 ? .empty : .missing
    }
}
