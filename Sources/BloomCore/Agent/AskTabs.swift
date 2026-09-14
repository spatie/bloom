import Foundation

/// Tab selection and working directories live beside the sessions they describe.
public enum AskTabs {
    public static let selectionKey = "ask.selectedSession"

    public static func directoryKey(_ id: SessionID) -> String { "ask.directory.\(id.rawValue)" }

    public static func selection(saved: String?, sessions: [Session]) -> SessionID? {
        sessions.first { $0.id.rawValue == saved }?.id ?? sessions.first?.id
    }

    public static func selectionAfterClosing(
        _ id: SessionID, selected: SessionID?, sessions: [Session]
    ) -> SessionID? {
        let remaining = sessions.filter { $0.id != id }
        if selected != id, remaining.contains(where: { $0.id == selected }) { return selected }
        let index = sessions.firstIndex { $0.id == id } ?? 0
        return remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    /// An explicitly chosen folder must exist. A missing volume must not silently change cwd.
    public static func prepareDirectory(_ path: String, databasePath: String) -> String? {
        if path.isEmpty { return AskConversation.prepareDirectory(besideDatabaseAt: databasePath) }
        let expanded = NewProjectPlan.expand(path, home: FileManager.default.homeDirectoryForCurrentUser.path)
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return FolderPath.normalize(expanded)
    }
}
