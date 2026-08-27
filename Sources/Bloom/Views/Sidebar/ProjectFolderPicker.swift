import AppKit

/// Asking the user for a project folder. Wrapped so the places that offer it cannot drift apart on
/// panel configuration. What happens to the folder afterwards is `AppModel.addProjectByAsking`,
/// for the same reason.
///
/// Two questions and so two panels below. `choose` is the file panel that acts on what it is
/// given, which is what the Settings window and the create window's empty state raise; `chooseTarget`
/// is the one inside `StartProjectSheet`, which writes its answer into a field and decides nothing.
/// The main window's own controls no longer raise the first of the two.
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
    /// Asking for the folder a project will be, from the sheet that has one field for it.
    ///
    /// A different question from `choose`, and so a different panel: the answer is written into
    /// the field rather than acted on, so the prompt says Choose rather than Add and nothing has
    /// been decided by the time the panel closes. It used to ask for the PARENT of a project that
    /// did not exist yet, which was the location half of two fields that are now one; the folder
    /// itself is a perfectly good answer here, whether it exists, is empty, or is a repository,
    /// because the block under the field says which of those it turned out to be.
    ///
    /// - Parameter startingAt: where to open, which the caller works out from what is in the
    ///   field: the target itself where it exists, and otherwise the deepest folder above it that
    ///   does, since a half typed path names a folder nobody has made.
    static func chooseTarget(startingAt path: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // A folder made here and handed straight back is an empty one, which the sheet adopts
        // rather than refuses. See `NewProjectVerdict.adopt`.
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder your project should live in."
        if let path, FileManager.default.fileExists(atPath: path) {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        guard await panel.present() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
