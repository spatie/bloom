import AppKit

/// Asking the user for a project folder. Wrapped so the four places that offer it (the toolbar,
/// the sidebar's empty state, Home's empty state and the new workspace sheet) cannot drift apart
/// on panel configuration. What happens to the folder afterwards is `AppModel.addProjectByAsking`,
/// for the same reason.
@MainActor
enum ProjectFolderPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add project"
        panel.message = "Choose the git repository you want to run agents in."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
