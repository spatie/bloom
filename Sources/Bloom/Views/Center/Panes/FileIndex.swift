import Foundation
import BloomCore

/// The list of files Bloom offers for `@mention`, cached per workspace.
///
/// `git ls-files` is fast but not free, and it is asked for again on every character typed after
/// the `@`. Thirty seconds is long enough that a burst of typing costs one process, and short
/// enough that a file added a moment ago shows up without restarting anything.
actor FileIndex {
    static let shared = FileIndex()

    private struct Entry {
        var paths: [String]
        var loadedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<[String], Never>] = [:]

    private let lifetime: TimeInterval = 30

    func files(workspacePath: String) async -> [String] {
        if let entry = cache[workspacePath], Date.now.timeIntervalSince(entry.loadedAt) < lifetime {
            return entry.paths
        }
        if let running = inFlight[workspacePath] {
            return await running.value
        }

        let task = Task<[String], Never> {
            let result = try? await Shell.run(
                "git",
                ["ls-files", "--cached", "--others", "--exclude-standard"],
                cwd: workspacePath,
                timeout: .seconds(10)
            )
            return result?.lines ?? []
        }
        inFlight[workspacePath] = task
        let paths = await task.value
        inFlight[workspacePath] = nil
        cache[workspacePath] = Entry(paths: paths, loadedAt: .now)
        return paths
    }

    /// Called after a turn finishes, when the agent may have created files.
    func invalidate(workspacePath: String) {
        cache[workspacePath] = nil
    }
}
