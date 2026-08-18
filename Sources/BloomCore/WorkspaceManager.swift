import Foundation

public struct WorkspaceCreation: Sendable {
    public var workspace: Workspace
    public var prompt: String
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case notARepository(String)
    case pathInUse(String)
    case repoMissing
    /// Archiving would destroy work that exists nowhere else. Carries the full report so the UI
    /// can list what is at stake instead of asking "are you sure?" about nothing in particular.
    case unsafeToArchive(WorkspaceSafetyReport)
    case archiveScriptFailed(status: Int32, output: String)

    public var description: String {
        switch self {
        case .notARepository(let path): "\(path) is not a git repository"
        case .pathInUse(let path): "\(path) already exists"
        case .repoMissing: "the workspace has no repository"
        case .unsafeToArchive(let report):
            "archiving would permanently destroy " + report.losses.joined(separator: ", ")
        case .archiveScriptFailed(let status, let output):
            "the archive script exited \(status), so nothing was removed: "
                + output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500)
        }
    }
}

/// Everything that happens to a workspace on disk. Deliberately has no idea the UI exists: it
/// takes a store and a repo and does git and shell work.
public struct WorkspaceManager: Sendable {
    public let store: Store

    public init(store: Store) {
        self.store = store
    }

    /// Where NEW worktrees are cut. Read at creation time and nowhere else: an existing workspace
    /// is opened through the absolute path in its `workspaces` row, so nothing here reaches back
    /// into worktrees that already exist.
    ///
    /// That is deliberate, and the rename did not move any of them. A worktree's location is
    /// recorded in three places at once: the database row, the `gitdir` file inside the worktree,
    /// and the admin file git keeps under the parent repository. Moving one means rewriting all
    /// three and running `git worktree repair`, and getting any part of it wrong strands work
    /// that only exists in that checkout. So `~/baton/workspaces` keeps every worktree already in
    /// it, forever, and only new ones land here.
    public static var workspacesRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("bloom/workspaces", isDirectory: true)
    }

    // MARK: - Repositories

    @discardableResult
    public func addRepository(at path: String) async throws -> Repo {
        let expanded = (path as NSString).expandingTildeInPath
        guard await Git.isRepository(expanded) else {
            throw WorkspaceError.notARepository(expanded)
        }
        let root = try await Git.topLevel(of: expanded)

        if let existing = try await store.repo(path: root) { return existing }

        let existingRepos = try await store.repos()
        let repo = Repo(
            name: (root as NSString).lastPathComponent,
            path: root,
            defaultBranch: try await Git.defaultBranch(of: root),
            accent: Accent.next(usedBy: existingRepos),
            sortOrder: existingRepos.count
        )
        return try await store.upsert(repo)
    }

    // MARK: - Creating workspaces

    /// Creates the branch, the worktree, copies the configured files and returns immediately.
    /// The setup script runs separately so the UI can stream its output.
    public func createWorkspace(
        repo: Repo,
        prompt: String,
        name: String? = nil,
        branch: String? = nil,
        baseBranch: String? = nil
    ) async throws -> Workspace {
        let settings = SettingsLoader.load(repo: repo.path)
        let base = baseBranch ?? repo.defaultBranch

        let existingBranches = Set(try await Git.branches(of: repo.path))
        var slug = branch ?? Git.slug(from: prompt)
        if let prefix = settings.branchPrefix, !prefix.isEmpty, branch == nil {
            slug = "\(prefix)/\(slug)"
        }
        let finalBranch = Git.uniqueBranch(slug, taken: existingBranches)

        let directoryName = finalBranch.replacingOccurrences(of: "/", with: "-")
        let root = Self.workspacesRoot.appendingPathComponent(repo.name, isDirectory: true)
        var worktreePath = root.appendingPathComponent(directoryName).path
        var suffix = 2
        while FileManager.default.fileExists(atPath: worktreePath) {
            worktreePath = root.appendingPathComponent("\(directoryName)-\(suffix)").path
            suffix += 1
        }

        try await Git.addWorktree(repo: repo.path, path: worktreePath, branch: finalBranch, base: base)

        try copyFiles(settings.filesToCopy, from: repo.path, to: worktreePath)

        let workspace = Workspace(
            repoID: repo.id,
            name: name ?? Git.title(from: prompt),
            branch: finalBranch,
            path: worktreePath,
            baseBranch: base,
            setupState: settings.setupScript == nil ? .skipped : .pending,
            sortOrder: try await store.nextWorkspaceSortOrder(repoID: repo.id)
        )
        return try await store.upsert(workspace)
    }

    /// Copies glob patterns like `.env*` from the main checkout into a fresh worktree.
    func copyFiles(_ patterns: [String], from source: String, to destination: String) throws {
        let manager = FileManager.default
        for pattern in patterns {
            let directory = (pattern as NSString).deletingLastPathComponent
            let filePattern = (pattern as NSString).lastPathComponent
            let searchDirectory = directory.isEmpty
                ? source
                : (source as NSString).appendingPathComponent(directory)

            guard let entries = try? manager.contentsOfDirectory(atPath: searchDirectory) else { continue }

            for entry in entries where matches(entry, pattern: filePattern) {
                let from = (searchDirectory as NSString).appendingPathComponent(entry)
                let relative = directory.isEmpty ? entry : "\(directory)/\(entry)"
                let to = (destination as NSString).appendingPathComponent(relative)

                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: from, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    continue
                }
                if manager.fileExists(atPath: to) { continue }

                try? manager.createDirectory(
                    atPath: (to as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try? manager.copyItem(atPath: from, toPath: to)
            }
        }
    }

    func matches(_ name: String, pattern: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else { return name == pattern }
        return fnmatch(pattern, name, 0) == 0
    }

    // MARK: - Scripts

    /// `CONDUCTOR_` is not a leftover. It is deliberate compatibility with Conductor, whose
    /// `.conductor/settings.toml` files this app reads, so a setup script written for that product
    /// binds the names it already expects.
    public static let environmentPrefixes = ["BLOOM", "CONDUCTOR"]

    public func environment(for workspace: Workspace, repo: Repo, port: Int) -> [String: String] {
        // Both prefixes carry the same values, so a script can bind whichever it was written
        // against.
        let pairs: [(String, String)] = [
            ("IS_LOCAL", "1"),
            ("WORKSPACE_NAME", workspace.branch.replacingOccurrences(of: "/", with: "-")),
            ("WORKSPACE_ID", workspace.id),
            ("WORKSPACE_PATH", workspace.path),
            ("ROOT_PATH", repo.path),
            ("DEFAULT_BRANCH", repo.defaultBranch),
            ("PORT", String(port)),
        ]

        var env: [String: String] = [:]
        for (key, value) in pairs {
            for prefix in Self.environmentPrefixes {
                env["\(prefix)_\(key)"] = value
            }
        }
        return env
    }

    /// Runs the setup script, streaming output line by line. Returns whether it succeeded.
    @discardableResult
    public func runSetup(
        workspace: Workspace,
        repo: Repo,
        port: Int,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let settings = SettingsLoader.load(repo: repo.path)
        guard let script = settings.setupScript, !script.isEmpty else {
            try? await store.updateSetup(workspaceID: workspace.id, state: .skipped)
            return true
        }

        try? await store.updateSetup(workspaceID: workspace.id, state: .running)

        let env = environment(for: workspace, repo: repo, port: port)
        let runner = StreamingProcess(
            executable: "/bin/zsh",
            arguments: ["-c", script],
            cwd: workspace.path,
            environment: Shell.environment(extra: env)
        )

        var log = ""
        do {
            for try await line in runner.lines {
                log += line + "\n"
                onOutput(line)
            }
        } catch {
            log += "\n\(error)\n"
            onOutput("\(error)")
        }

        let status = await runner.exitStatus
        let succeeded = status == 0
        let capped = String(log.suffix(200_000))
        // The whole `workspace` value here is as old as the run, and a run can take minutes, so
        // upserting it would clobber every other write to the row made in the meantime.
        try? await store.updateSetup(
            workspaceID: workspace.id,
            state: succeeded ? .succeeded : .failed,
            log: capped
        )
        return succeeded
    }

    // MARK: - Archiving

    /// What archiving this workspace would throw away. Call it before `archive` to build a
    /// confirmation the user can actually judge.
    public func safetyReport(workspace: Workspace, repo: Repo) async throws -> WorkspaceSafetyReport {
        try await Git.safetyReport(
            worktree: workspace.path,
            branch: workspace.branch,
            base: workspace.baseBranch,
            repo: repo.path
        )
    }

    /// Removes the worktree and, optionally, the branch.
    ///
    /// Archiving is not undoable: once the worktree is gone the uncommitted files are gone, and
    /// once the branch is gone commits nothing else points at are unreachable. So unless the
    /// caller passes `force`, this refuses up front and throws a report of what is at stake,
    /// before it has touched anything.
    /// - Parameter isPullRequestMerged: GitHub's own answer for this branch, when the caller has
    ///   one. Nothing here can ask: `gh` lives above this layer and a report that shelled out to
    ///   the network would make every archive wait on it. Passing it in is what stops a squash
    ///   merged branch, which git calls unmerged, from being refused as unsafe.
    public func archive(
        workspace: Workspace,
        repo: Repo,
        deleteBranch: Bool? = nil,
        force: Bool = false,
        isPullRequestMerged: Bool = false
    ) async throws {
        let settings = SettingsLoader.load(repo: repo.path)
        let shouldDeleteBranch = deleteBranch ?? settings.deleteBranchOnArchive

        let report: WorkspaceSafetyReport?
        if force {
            // A forced archive still wants the report, to decide how hard to push on the branch,
            // but must not be blocked by a repository too broken to answer.
            report = try? await safetyReport(workspace: workspace, repo: repo)
        } else {
            let computed = try await safetyReport(workspace: workspace, repo: repo)
            guard computed.isSafeToDiscard(
                deletingBranch: shouldDeleteBranch, isPullRequestMerged: isPullRequestMerged
            ) else {
                throw WorkspaceError.unsafeToArchive(computed)
            }
            report = computed
        }

        // A failing archive script means the workspace was not wound down: containers still
        // running, a database still there. Deleting the worktree anyway leaves that mess with
        // nothing left to clean it up from.
        if let script = settings.archiveScript, !script.isEmpty,
           FileManager.default.fileExists(atPath: workspace.path) {
            let env = environment(for: workspace, repo: repo, port: 0)
            let result = try await Shell.script(script, cwd: workspace.path, env: env, timeout: .seconds(120))
            guard result.ok else {
                throw WorkspaceError.archiveScriptFailed(
                    status: result.status,
                    output: result.stderr.isEmpty ? result.stdout : result.stderr
                )
            }
        }

        try await Git.removeWorktree(repo: repo.path, path: workspace.path, force: force)

        if shouldDeleteBranch {
            do {
                try await Git.deleteBranch(workspace.branch, in: repo.path)
            } catch {
                // `git branch -d` only looks at the upstream and at HEAD, so it refuses branches
                // whose commits are safely on a remote or on another branch. The safety report
                // checked every ref, so when it cleared the branch, -D destroys nothing.
                let cleared = report?.isSafeToDiscard(
                    deletingBranch: true, isPullRequestMerged: isPullRequestMerged
                ) == true
                guard force || cleared else { throw error }
                try await Git.deleteBranch(workspace.branch, in: repo.path, force: true)
            }
        }

        try await store.upsert(workspace.with {
            $0.state = .archived
            $0.archivedAt = Date()
        })
    }

    /// Deliberately leaves the stored counts alone when git fails, rather than writing zeroes.
    /// A stale count is a small lie; "0 files changed" on a workspace full of work is a big one.
    public func refreshDiffStat(workspace: Workspace) async {
        guard let stat = try? await Git.diffStat(worktree: workspace.path, base: workspace.baseBranch) else {
            return
        }
        try? await store.updateDiffStat(
            workspaceID: workspace.id,
            additions: stat.additions,
            deletions: stat.deletions,
            files: stat.files
        )
    }
}

public extension Workspace {
    /// Small mutation helper so call sites read as one statement.
    func with(_ change: (inout Workspace) -> Void) -> Workspace {
        var copy = self
        change(&copy)
        return copy
    }
}

public extension Session {
    func with(_ change: (inout Session) -> Void) -> Session {
        var copy = self
        change(&copy)
        return copy
    }
}

public extension Repo {
    func with(_ change: (inout Repo) -> Void) -> Repo {
        var copy = self
        change(&copy)
        return copy
    }
}

public enum PortAllocatorError: Error, CustomStringConvertible {
    case exhausted(start: Int, limit: Int)

    public var description: String {
        switch self {
        case .exhausted(let start, let limit):
            "no free block of ten ports between \(start) and \(limit)"
        }
    }
}

/// Assigns each active workspace a block of ten ports, the way Conductor does, so a run script
/// can bind `$BLOOM_PORT` without colliding with a sibling workspace.
public enum PortAllocator {
    public static let blockSize = 10

    /// The first port of a free block of ten.
    ///
    /// Throws rather than falling back to `start`. Handing back a port something else is already
    /// listening on sends a run script into a bind failure, or worse, into someone else's server.
    /// Every port in the block is probed, because the block is the promise being made.
    public static func allocate(taken: Set<Int>, start: Int = 3_100, limit: Int = 65_000) throws -> Int {
        var port = start
        while port + blockSize - 1 <= limit {
            if isBlockAvailable(from: port, taken: taken) { return port }
            port += blockSize
        }
        throw PortAllocatorError.exhausted(start: start, limit: limit)
    }

    static func isBlockAvailable(from start: Int, taken: Set<Int>) -> Bool {
        for port in start..<(start + blockSize) {
            if taken.contains(port) || !isFree(port) { return false }
        }
        return true
    }

    static func isFree(_ port: Int) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return true }
        defer { close(handle) }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}
