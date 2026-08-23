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
    static func pullRequest(
        branch: String, worktree: String, maxAge: Duration = .zero
    ) async -> PullRequest? {
        guard await GitHubAvailability.shared.isReady() else { return nil }
        return try? await GitHub.pullRequest(
            forBranch: branch, worktree: worktree, maxAge: maxAge
        )
    }

    static func checks(branch: String, worktree: String) async -> [CheckRun] {
        (try? await GitHub.checks(forBranch: branch, worktree: worktree)) ?? []
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

    /// Walks a short, fixed list of editors and opens the folder in the first one installed,
    /// falling back to Finder. Not the app the user has associated with folders: that
    /// association is Finder on nearly every machine, so asking LaunchServices would answer
    /// Finder for the people this menu item exists for.
    static func inEditor(_ path: String) {
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
