import Foundation
import AppKit
import BloomCore

/// The one place the app layer touches `GitHub`. Keeping it behind a single adapter means a
/// change to the gh wrapper's signature is a one-file fix rather than a sweep through views.
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

    /// The branch is deleted on GitHub and nowhere else. See `GitHub.merge` for why the local half
    /// of gh's own clean up can never be used from a worktree.
    static func merge(
        _ pullRequest: PullRequest, worktree: String, method: GitHub.MergeMethod
    ) async throws -> MergeOutcome {
        try await GitHub.merge(
            number: pullRequest.number,
            branch: pullRequest.branch,
            worktree: worktree,
            method: method,
            deleteRemoteBranch: true
        )
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
        let script = "tell application \"Terminal\" to do script \"cd \(path.replacingOccurrences(of: "\"", with: "\\\""))\""
        guard let apple = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
    }

    /// Prefers whatever the user has associated with the folder, which for most developers is
    /// their editor rather than Finder.
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
