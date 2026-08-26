import Foundation
import AppKit
import BloomCore

/// The one place the app layer touches `GitHub`. Keeping it behind a single adapter means a
/// change to the gh wrapper's signature is a one-file fix rather than a sweep through views.
///
/// It asks GitHub questions and nothing else. Opening a pull request, pushing a branch and merging
/// are all turns sent to the workspace's agent now, so the only `gh` this app runs is the reading
/// half.
enum GitHubBridge {
    /// - Parameter maxAge: how old an answer from the last `gh pr view` may be and still be used.
    ///   Zero always asks GitHub.
    ///
    /// Availability goes through `GitHubAvailability` rather than straight to `GitHub`, and that
    /// is the difference between one gh call and two. `GitHub.isAvailable()` runs `gh auth
    /// status`, which is a process launch and a round trip to GitHub, and this was calling it
    /// before every single `gh pr view`: arriving at a workspace cost two network calls to answer
    /// one question. `GitHubAvailability` already asks that question once and remembers the
    /// answer, expiring only the negative one, because signing in happens outside this app.
    ///
    /// The workspace goes in whole rather than as a branch and a path, because the branch name is
    /// not enough to say which pull request is this one's. See `PullRequestOwnership`.
    static func pullRequest(
        for workspace: Workspace, maxAge: Duration = .zero
    ) async -> PullRequest? {
        guard await GitHubAvailability.shared.isReady() else { return nil }
        return try? await GitHub.pullRequest(for: workspace, maxAge: maxAge)
    }

    static func checks(for workspace: Workspace) async -> [CheckRun] {
        (try? await GitHub.checks(for: workspace)) ?? []
    }

    static func open(_ url: String) {
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }
}

/// Opens a path in the user's editor or in Finder. Used by the file list and the sidebar's
/// context menus.
enum Reveal {
    static func inFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    static func inTerminal(_ path: String) {
        // Backslash first, then the quote: escaping quotes alone left a trailing backslash
        // in a path free to swallow the closing quote, and with it the rest of the line
        // became part of a string handed to `do script`.
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"cd \(escaped)\""
        guard let apple = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
    }

    /// Opens a path in the editor this project was last opened in.
    ///
    /// **It used to ignore that entirely**, and `OpenInMenu`'s header recorded the consequence and
    /// declined to fix it: ⇧⌘E and the "Open File in" submenu could open two different editors on
    /// the same Mac, agreeing only by coincidence on one where VS Code happens to be the answer to
    /// both. A Zed or a Sublime user got their choice from the submenu and VS Code from the menu
    /// bar. `OpenIn.preferred` is the same question the submenu asks, so both now get one answer.
    ///
    /// The fixed ladder below is still what answers when nothing is installed that the catalogue
    /// knows, and its own reason is unchanged: NOT the app the user has associated with folders,
    /// because that association is Finder on nearly every machine and would answer Finder for
    /// exactly the people this item exists for.
    ///
    /// - Parameter repo: whose choice to honour. Nil where the caller genuinely has no project in
    ///   hand, which falls back to whatever was last used anywhere, as the submenu does.
    @MainActor
    static func inEditor(_ path: String, repo: RepoID? = nil) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let target: OpenInTarget = isDirectory.boolValue ? .folder(path) : .file(path)
        if let app = OpenIn.preferred(for: target, repo: repo) {
            OpenIn.open(path, with: app, repo: repo)
            return
        }

        let url = URL(fileURLWithPath: path)
        for bundleID in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(
                    [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
                )
                return
            }
        }
        NSWorkspace.shared.open(url)
    }
}
