import AppKit
import BloomCore

/// Opens a settings file where the owner edits files.
///
/// The editor this project was last opened in, through the same `OpenIn` the inspector's rows
/// use, so the file lands beside the rest of the project's work. With nothing to open it in, the
/// file is shown in Finder rather than handed to whatever the system thinks a `.toml` is.
@MainActor
enum SettingsFileOpener {
    static func open(_ path: String, repo: RepoID) {
        if let app = OpenIn.preferred(for: .file(path), repo: repo) {
            OpenIn.open(path, with: app, repo: repo)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
        }
    }
}
