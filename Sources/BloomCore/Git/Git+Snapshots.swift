import Foundation

extension Git {
    /// The real index is only read. Each capture has independent indexes in the Git directory,
    /// so simultaneous sessions cannot overwrite each other's staging or checkpoint files.
    public static func captureSnapshot(in worktree: String, sessionID: SessionID) async throws -> GitSnapshot {
        try await validateSnapshotWorktree(worktree)
        let gitDirectory = try await check(["rev-parse", "--absolute-git-dir"], in: worktree).trimmed
        let indexPath = (gitDirectory as NSString).appendingPathComponent("index")
        let snapshot = GitSnapshot(sessionID: sessionID, indexWasPresent: FileManager.default.fileExists(atPath: indexPath))
        let temporary = (gitDirectory as NSString).appendingPathComponent("bloom-snapshot-\(snapshot.id)")
        let workIndex = temporary + "-work"
        let savedIndex = temporary + "-index"
        defer {
            for path in [workIndex, savedIndex, workIndex + ".lock", savedIndex + ".lock"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if FileManager.default.fileExists(atPath: indexPath + ".lock") {
            throw SnapshotFailure("Git is updating the index. Try again when it has finished.")
        }
        if FileManager.default.fileExists(atPath: indexPath) {
            try FileManager.default.copyItem(atPath: indexPath, toPath: savedIndex)
        } else {
            _ = try await snapshotCommand(["read-tree", "--empty"], in: worktree, index: savedIndex)
        }
        do {
            // A split index references an expiring sharedindex file. Store a standalone index
            // blob so intent-to-add and per-path flags survive both GC and a tree round trip.
            _ = try await snapshotCommand(["update-index", "--no-split-index"], in: worktree, index: savedIndex)
            let rawIndex = try await snapshotCommand(["hash-object", "-w", "--", savedIndex], in: worktree).trimmed
            _ = try await snapshotCommand(["update-ref", snapshot.rawIndexRef, rawIndex], in: worktree)
            try FileManager.default.copyItem(atPath: savedIndex, toPath: workIndex)
            // Worktree capture must read real file contents even when the owner's index tells
            // ordinary Git commands to skip them. Names travel as NUL-delimited bytes.
            let paths = try await snapshotBytes(["ls-files", "-z"], in: worktree, index: workIndex)
            for flag in ["--no-assume-unchanged", "--no-skip-worktree"] {
                _ = try await snapshotBytes(["update-index", flag, "-z", "--stdin"],
                                            in: worktree, index: workIndex, stdin: paths)
            }
            _ = try await snapshotCommand(["add", "-A", "--", "."], in: worktree, index: workIndex)
            for (index, ref) in [(savedIndex, snapshot.indexRef), (workIndex, snapshot.worktreeRef)] {
                let tree = try await snapshotCommand(["write-tree"], in: worktree, index: index).trimmed
                let commit = try await snapshotCommand(
                    ["commit-tree", tree, "-m", "Bloom workspace snapshot"], in: worktree, index: index
                ).trimmed
                _ = try await snapshotCommand(["update-ref", ref, commit], in: worktree, index: index)
            }
            return snapshot
        } catch {
            await Task.detached { try? await deleteSnapshot(snapshot, in: worktree) }.value
            throw error
        }
    }

    public static func deleteSnapshot(_ snapshot: GitSnapshot, in worktree: String) async throws {
        try validateSnapshot(snapshot)
        for ref in [snapshot.worktreeRef, snapshot.indexRef, snapshot.rawIndexRef] {
            _ = try await snapshotCommand(["update-ref", "-d", ref], in: worktree)
        }
    }

    private static func validateSnapshot(_ snapshot: GitSnapshot) throws {
        guard UUID(uuidString: snapshot.id.rawValue) != nil else { throw SnapshotFailure("Invalid snapshot identifier.") }
    }

    private static func validateSnapshotWorktree(_ worktree: String) async throws {
        guard FileManager.default.fileExists(atPath: worktree) else { throw SnapshotFailure("The workspace no longer exists.") }
        let root = try await check(["rev-parse", "--show-toplevel"], in: worktree).trimmed
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().path == URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path else {
            throw SnapshotFailure("The workspace is not the root of its Git checkout.")
        }
    }

    private static func snapshotBytes(
        _ arguments: [String], in worktree: String, index: String? = nil, stdin: Data? = nil
    ) async throws -> Data {
        var environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        if let index { environment["GIT_INDEX_FILE"] = index }
        let result = try await Shell.runBytes("git", arguments, cwd: worktree, env: environment,
                                              stdin: stdin, timeout: .seconds(30))
        guard result.status == 0 else { throw SnapshotFailure(String(decoding: result.stderr, as: UTF8.self)) }
        return result.stdout
    }

    private static func snapshotCommand(
        _ arguments: [String], in worktree: String, index: String? = nil
    ) async throws -> ShellResult {
        var environment = [
            "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Bloom", "GIT_AUTHOR_EMAIL": "snapshot@localhost",
            "GIT_COMMITTER_NAME": "Bloom", "GIT_COMMITTER_EMAIL": "snapshot@localhost",
        ]
        if let index { environment["GIT_INDEX_FILE"] = index }
        let result = try await Shell.run("git", arguments, cwd: worktree, env: environment, timeout: .seconds(30))
        guard result.ok else { throw SnapshotFailure(result.stderr.isEmpty ? result.stdout : result.stderr) }
        return result
    }
}
