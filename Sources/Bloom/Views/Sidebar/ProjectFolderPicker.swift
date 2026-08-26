import AppKit

/// Asking the user for a project folder. Wrapped so the four places that offer it (the toolbar,
/// the sidebar's empty state, Home's empty state and the new workspace sheet) cannot drift apart
/// on panel configuration. What happens to the folder afterwards is `AppModel.addProjectByAsking`,
/// for the same reason.
@MainActor
enum ProjectFolderPicker {
    /// A sheet rather than an application-modal panel, for the reason `NSSavePanel.present`
    /// gives: `runModal()` would stop every other workspace's transcript from streaming for as
    /// long as the folder picker is open.
    static func choose() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // A new folder is now a perfectly good answer: an empty one becomes a repository with an
        // empty first commit, which is exactly what a branch needs.
        panel.canCreateDirectories = true
        panel.prompt = "Add project"
        // It no longer has to be a repository. `AppModel.addRepository` offers to make one out of
        // a folder that is not, so asking for a repository here would turn the offer into a
        // secret.
        panel.message = "Choose the folder you want to run agents in."
        guard await panel.present() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

extension ProjectFolderPicker {
    /// Asking where a project that does not exist yet should be put.
    ///
    /// A different question from `choose`, and so a different panel: this one is answered with the
    /// PARENT folder, the project's own folder does not exist and is not meant to be made here,
    /// and the prompt therefore says Choose rather than Add. `NewProjectSheet` makes the folder
    /// itself, which is the whole reason that sheet exists.
    ///
    /// - Parameter startingAt: the location already in the field, so the panel opens where the
    ///   person is rather than where they were last.
    static func chooseLocation(startingAt path: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder your new project should be created in."
        if let path, FileManager.default.fileExists(atPath: path) {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        guard await panel.present() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
