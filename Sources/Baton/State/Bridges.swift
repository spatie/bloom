import Foundation
import AppKit
import BatonCore

/// The one place the app layer touches `GitHub`. Keeping it behind a single adapter means a
/// change to the gh wrapper's signature is a one-file fix rather than a sweep through views.
enum GitHubBridge {
    static func pullRequest(branch: String, worktree: String) async -> PullRequest? {
        guard await GitHub.isAvailable() else { return nil }
        return try? await GitHub.pullRequest(forBranch: branch, worktree: worktree)
    }

    static func checks(branch: String, worktree: String) async -> [CheckRun] {
        (try? await GitHub.checks(forBranch: branch, worktree: worktree)) ?? []
    }

    static func merge(_ pullRequest: PullRequest, worktree: String, method: GitHub.MergeMethod) async throws {
        try await GitHub.merge(
            number: pullRequest.number, worktree: worktree, method: method, deleteBranch: true
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
