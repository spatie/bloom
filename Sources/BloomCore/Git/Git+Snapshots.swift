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

    public static func snapshotDiff(
        from before: GitSnapshot, to after: GitSnapshot, in worktree: String, path: String? = nil
    ) async throws -> String {
        try validateSnapshot(before)
        try validateSnapshot(after)
        var arguments = [
            "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "--src-prefix=a/", "--dst-prefix=b/", "-M", before.worktreeRef, after.worktreeRef, "--",
        ]
        if let path { arguments.append(path) }
        return try await snapshotCommand(arguments, in: worktree).stdout
    }

    /// Preflight never changes workspace files or the real index. A rejected restore must not
    /// create a recovery journal that would itself require the same unsupported restore.
    public static func validateSnapshotRestore(_ target: GitSnapshot, in worktree: String) async throws {
        _ = try await snapshotRestorePreparation(target, in: worktree)
    }

    /// Callers persist a recovery snapshot first and exclude running sessions. Validation is
    /// repeated under Git's index lock because conditions may change after the earlier preflight.
    public static func restoreSnapshot(_ target: GitSnapshot, in worktree: String) async throws {
        try await validateSnapshotWorktree(worktree)
        let gitDirectory = try await check(["rev-parse", "--absolute-git-dir"], in: worktree).trimmed
        let indexLease = try GitSnapshotIndex(directory: gitDirectory)
        defer { indexLease.release() }
        let prepared = try await snapshotRestorePreparation(target, in: worktree)
        let restoreIndex = (gitDirectory as NSString).appendingPathComponent("bloom-restore-\(UUID().uuidString)")
        defer {
            for path in [restoreIndex, restoreIndex + ".lock"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if FileManager.default.fileExists(atPath: indexLease.indexPath) {
            try FileManager.default.copyItem(atPath: indexLease.indexPath, toPath: restoreIndex)
        } else {
            _ = try await snapshotCommand(["read-tree", "--empty"], in: worktree, index: restoreIndex)
        }
        let restorePaths = try await snapshotBytes(["ls-files", "-z"], in: worktree, index: restoreIndex)
        for flag in ["--no-assume-unchanged", "--no-skip-worktree"] {
            _ = try await snapshotBytes(["update-index", flag, "-z", "--stdin"],
                                        in: worktree, index: restoreIndex, stdin: restorePaths)
        }
        // git restore refuses an empty pathspec match in a wholly empty repository.
        if !prepared.wanted.isEmpty || !prepared.current.isEmpty {
            _ = try await snapshotCommand(
                ["restore", "--ignore-skip-worktree-bits", "--source", target.worktreeRef, "--worktree", "--staged", "--", "."], in: worktree, index: restoreIndex
            )
        }
        for path in prepared.extras {
            _ = try await snapshotCommand(["--literal-pathspecs", "clean", "-f", "-x", "--", path], in: worktree)
        }
        try Task.checkCancellation()
        try indexLease.install(prepared.indexWasPresent ? prepared.rawIndex : nil)
    }

    private struct SnapshotRestorePreparation {
        let indexWasPresent: Bool
        let rawIndex: Data
        let wanted: [String]
        let current: [String]
        let extras: [String]
    }

    private static func snapshotRestorePreparation(
        _ target: GitSnapshot, in worktree: String
    ) async throws -> SnapshotRestorePreparation {
        try validateSnapshot(target)
        try await validateSnapshotWorktree(worktree)
        _ = try await snapshotCommand(["rev-parse", "--verify", target.worktreeRef + "^{tree}"], in: worktree)
        _ = try await snapshotCommand(["rev-parse", "--verify", target.indexRef + "^{tree}"], in: worktree)
        guard let indexWasPresent = target.indexWasPresent else {
            throw SnapshotFailure("This older snapshot does not preserve complete staging metadata. Files were not restored.")
        }
        let rawIndex = try await snapshotBytes(["cat-file", "blob", target.rawIndexRef], in: worktree)
        let gitDirectory = try await check(["rev-parse", "--absolute-git-dir"], in: worktree).trimmed
        let validationIndex = (gitDirectory as NSString).appendingPathComponent("bloom-restore-validation-\(UUID().uuidString)")
        defer {
            for path in [validationIndex, validationIndex + ".lock"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try rawIndex.write(to: URL(fileURLWithPath: validationIndex))
        let validatedTree = try await snapshotCommand(["write-tree"], in: worktree, index: validationIndex).trimmed
        let expectedTree = try await snapshotCommand(["rev-parse", target.indexRef + "^{tree}"], in: worktree).trimmed
        guard validatedTree == expectedTree else { throw SnapshotFailure("The saved Git index is inconsistent. Files were not restored.") }
        let sparse = try await run(["config", "--bool", "core.sparseCheckout"], in: worktree)
        if sparse.ok && sparse.trimmed == "true" {
            throw SnapshotFailure("Restoring files is unavailable in a sparse checkout.")
        }
        let tree = try await snapshotCommand(["ls-tree", "-r", "-z", target.worktreeRef], in: worktree)
        if tree.stdout.split(separator: "\0").contains(where: { $0.hasPrefix("160000 ") }) {
            throw SnapshotFailure("Restoring files is unavailable for snapshots containing submodules.")
        }
        let wanted = try await snapshotPaths(["ls-tree", "--name-only", "-r", "-z", target.worktreeRef], in: worktree)
        let ignored = try await snapshotPaths(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], in: worktree)
        if ignored.contains(where: { path in wanted.contains { $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") } }) {
            throw SnapshotFailure("An ignored file would be replaced by this snapshot. Move it before restoring files.")
        }
        let extras = try await snapshotPaths(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
            .filter { !wanted.contains($0) }
        if extras.contains(where: { $0.hasSuffix("/") }) {
            throw SnapshotFailure("A nested repository is outside the snapshot. Move it before restoring files.")
        }
        let current = try await snapshotPaths(["ls-files", "--cached", "-z"], in: worktree)
        return SnapshotRestorePreparation(indexWasPresent: indexWasPresent, rawIndex: rawIndex,
                                          wanted: wanted, current: current, extras: extras)
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

    private static func snapshotPaths(_ arguments: [String], in worktree: String) async throws -> [String] {
        let result = try await Shell.runBytes(
            "git", arguments, cwd: worktree, env: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(30)
        )
        guard result.status == 0 else { throw SnapshotFailure(String(decoding: result.stderr, as: UTF8.self)) }
        return try nulRecords(result.stdout).map {
            guard let path = String(data: $0, encoding: .utf8) else {
                throw SnapshotFailure("A filename cannot be represented safely. Files were not restored.")
            }
            return path
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
