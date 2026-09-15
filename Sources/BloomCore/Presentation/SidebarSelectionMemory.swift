import Foundation

/// Selection preferences contain navigation IDs only, never conversation drafts or server data.
public enum SidebarSelectionMemory {
    public static let localWorkspaceKey = "sidebar.lastWorkspaceID"
    public static let remoteSessionKey = "sidebar.lastRemoteSessionID"
    public static let remoteWorkspaceKey = "sidebar.lastRemoteWorkspaceID"

    public static func clearRemote(in defaults: UserDefaults) {
        defaults.removeObject(forKey: remoteSessionKey)
        defaults.removeObject(forKey: remoteWorkspaceKey)
    }

    public static func remember(_ selection: SidebarSelection, in defaults: UserDefaults) {
        clearRemote(in: defaults)
        if let id = selection.remoteWorkspaceID {
            defaults.set(id.rawValue, forKey: remoteWorkspaceKey)
        } else if let id = selection.remoteSessionID {
            defaults.set(id.rawValue, forKey: remoteSessionKey)
        } else if let id = selection.workspaceID {
            defaults.set(id.rawValue, forKey: localWorkspaceKey)
        }
    }

    public static func savedRemote(in defaults: UserDefaults) -> SidebarSelection? {
        if let id = defaults.string(forKey: remoteWorkspaceKey) { return .remoteWorkspace(WorkspaceID(id)) }
        if let id = defaults.string(forKey: remoteSessionKey) { return .remote(SessionID(id)) }
        return nil
    }

    public static func contains(_ selection: SidebarSelection, workspaceIDs: Set<WorkspaceID>, sessionIDs: Set<SessionID>) -> Bool {
        if let id = selection.remoteWorkspaceID { return workspaceIDs.contains(id) }
        if let id = selection.remoteSessionID { return sessionIDs.contains(id) }
        return false
    }
}
