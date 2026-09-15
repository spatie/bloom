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
        let cleanIndex = temporary + "-clean"
        defer {
            for path in [workIndex, savedIndex, cleanIndex, workIndex + ".lock", savedIndex + ".lock", cleanIndex + ".lock"] {
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
            let listing = try await snapshotBytes(["ls-files", "-s", "-z"], in: worktree, index: workIndex)
            let paths = pathsByStage(listing)
            // Only clean entries. A path with conflict stages has no stage 0 entry to flag, and
            // `update-index` died on the first one with "Unable to mark file", so every turn sent
            // while an agent was resolving a merge failed to capture.
            for flag in ["--no-assume-unchanged", "--no-skip-worktree"] {
                _ = try await snapshotBytes(["update-index", flag, "-z", "--stdin"],
                                            in: worktree, index: workIndex, stdin: paths.merged)
            }
            // `add` records the conflicted file as it stands on disk, which is what a turn changes.
            _ = try await snapshotCommand(["add", "-A", "--", "."], in: worktree, index: workIndex)
            // `write-tree` refuses an index with conflict stages in it. The staged tree drops those
            // paths; the raw index blob above still holds every stage.
            var stagedIndex = savedIndex
            if !paths.unmerged.isEmpty {
                stagedIndex = cleanIndex
                try FileManager.default.copyItem(atPath: savedIndex, toPath: cleanIndex)
                _ = try await snapshotBytes(["update-index", "--force-remove", "-z", "--stdin"],
                                            in: worktree, index: cleanIndex, stdin: paths.unmerged)
            }
            for (index, ref) in [(stagedIndex, snapshot.indexRef), (workIndex, snapshot.worktreeRef)] {
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

    /// `ls-files -s -z` split into paths with a clean entry and paths with conflict stages, each
    /// NUL terminated for `update-index -z --stdin`. Bytes throughout, since a path need not be UTF-8.
    private static func pathsByStage(_ listing: Data) -> (merged: Data, unmerged: Data) {
        var merged = Data()
        var unmerged = Data()
        var seen = Set<Data>()
        for entry in listing.split(separator: 0) {
            guard let tab = entry.firstIndex(of: UInt8(ascii: "\t")), tab > entry.startIndex else { continue }
            let path = Data(entry[entry.index(after: tab)...])
            if entry[entry.index(before: tab)] == UInt8(ascii: "0") {
                merged.append(path)
                merged.append(0)
            } else if seen.insert(path).inserted {
                unmerged.append(path)
                unmerged.append(0)
            }
        }
        return (merged, unmerged)
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
