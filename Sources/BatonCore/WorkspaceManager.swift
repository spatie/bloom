import Foundation

public struct WorkspaceCreation: Sendable {
    public var workspace: Workspace
    public var prompt: String
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case notARepository(String)
    case pathInUse(String)
    case repoMissing

    public var description: String {
        switch self {
        case .notARepository(let path): "\(path) is not a git repository"
        case .pathInUse(let path): "\(path) already exists"
        case .repoMissing: "the workspace has no repository"
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

    public static var workspacesRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("baton/workspaces", isDirectory: true)
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

    public func environment(for workspace: Workspace, repo: Repo, port: Int) -> [String: String] {
        // Both prefixes are exported, so setup scripts written for Conductor keep working.
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
            env["BATON_\(key)"] = value
            env["CONDUCTOR_\(key)"] = value
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
            _ = try? await store.upsert(workspace.with { $0.setupState = .skipped })
            return true
        }

        _ = try? await store.upsert(workspace.with { $0.setupState = .running })

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
        _ = try? await store.upsert(workspace.with {
            $0.setupState = succeeded ? .succeeded : .failed
            $0.setupLog = capped
        })
        return succeeded
    }

    // MARK: - Archiving

    public func archive(workspace: Workspace, repo: Repo, deleteBranch: Bool? = nil) async throws {
        let settings = SettingsLoader.load(repo: repo.path)

        if let script = settings.archiveScript, !script.isEmpty,
           FileManager.default.fileExists(atPath: workspace.path) {
            let env = environment(for: workspace, repo: repo, port: 0)
            _ = try? await Shell.script(script, cwd: workspace.path, env: env, timeout: .seconds(120))
        }

        try await Git.removeWorktree(repo: repo.path, path: workspace.path)

        if deleteBranch ?? settings.deleteBranchOnArchive {
            try await Git.deleteBranch(workspace.branch, in: repo.path)
        }

        try await store.upsert(workspace.with {
            $0.state = .archived
            $0.archivedAt = Date()
        })
    }

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

/// Assigns each active workspace a block of ten ports, the way Conductor does, so a run script
/// can bind `$BATON_PORT` without colliding with a sibling workspace.
public enum PortAllocator {
    public static func allocate(taken: Set<Int>, start: Int = 3_100) -> Int {
        var port = start
        while taken.contains(port) || !isFree(port) {
            port += 10
            if port > 65_000 { return start }
        }
        return port
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
