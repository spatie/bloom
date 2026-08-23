import Foundation

public enum WorkspaceError: Error, CustomStringConvertible {
    case notARepository(String)
    case pathInUse(String)
    /// Archiving would destroy work that exists nowhere else. Carries the full report so the UI
    /// can list what is at stake instead of asking "are you sure?" about nothing in particular.
    case unsafeToArchive(WorkspaceSafetyReport)
    case archiveScriptFailed(status: Int32, output: String)
    /// The row was read, the work was done, and by the time it came to write the result there was
    /// no such workspace in the database any more. Only reachable when the project it belonged to
    /// was removed while this was running, which cascades its workspaces away.
    case workspaceGone(String)

    public var description: String {
        switch self {
        case .notARepository(let path): "\(path) is not a git repository"
        case .pathInUse(let path): "\(path) already exists"
        case .unsafeToArchive(let report):
            "archiving would permanently destroy " + report.losses.joined(separator: ", ")
        case .archiveScriptFailed(let status, let output):
            "the archive script exited \(status), so nothing was removed: "
                + output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500)
        case .workspaceGone(let name): "\(name) is no longer in the database"
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
        // Detection is done here, once, and stored. It is a bounded read of a fixed list of
        // directories, so it costs less than the `git` calls on either side of it, and doing it
        // now is what keeps the sidebar from touching the file system while it draws. A project
        // whose folder has nothing to find lands on `.monogram`: looked at, and answered.
        let icon = await Task.detached { RepoIconDetector.detect(in: root) }.value
        let repo = Repo(
            name: (root as NSString).lastPathComponent,
            path: root,
            defaultBranch: try await Git.defaultBranch(of: root),
            accent: Accent.next(usedBy: existingRepos),
            sortOrder: existingRepos.count,
            iconPath: icon?.path,
            iconSource: icon == nil ? .monogram : .detected
        )
        return try await store.upsert(repo)
    }

    // MARK: - Creating workspaces

    /// Creates the branch, the worktree, copies the configured files and returns immediately.
    /// The setup script runs separately so the UI can stream its output.
    ///
    /// This is the lower half of starting a workspace and it does none of the orchestration: no
    /// session row, no setup run, no naming, no idea who asked for it. `WorkspaceManager.start` is
    /// the whole of that and is what a route calls.
    ///
    /// **Internal, and that is the point.** It was public, and every route that reached it grew
    /// its own half of the orchestration around it: the create sheet had all of it, the `bloom://`
    /// link and the Services menu had none of it, and the Shortcuts intent could not reach it at
    /// all and polled the database instead. Internal means the app target cannot call this, so the
    /// compiler holds the line for every route outside the core, and `Tools/house-rules.sh` holds
    /// the remaining half: a new file inside the core naming it. The suite still reaches it
    /// through `@testable`, because a test wanting a worktree and nothing else is not a route.
    ///
    /// - Parameter origin: who asked. Defaults to the owner because that is what this primitive
    ///   has always meant and what every test of it is about. The place where the answer cannot be
    ///   forgotten is `WorkspaceStartRequest`, whose initialiser has no default for it, and every
    ///   route that could have an agent behind it goes through that.
    @discardableResult
    func createWorkspace(
        repo: Repo,
        prompt: String,
        name: String? = nil,
        branch: String? = nil,
        baseBranch: String? = nil,
        origin: WorkspaceOrigin = .user,
        checkout: WorkspaceCheckout? = nil
    ) async throws -> Workspace {
        // Everything below reads the repository and then acts on what it read, so two creates
        // running at once in one project decide on the same branch and the same directory and the
        // second one loses. See `WorktreeCutQueue` for why this is serialised rather than
        // coalesced.
        try await WorktreeCutQueue.shared.cut(in: repo.path) {
            if let checkout {
                return try await open(checkout, repo: repo, name: name, origin: origin)
            }
            return try await cut(
                repo: repo, prompt: prompt, name: name, branch: branch,
                baseBranch: baseBranch, origin: origin
            )
        }
    }

    /// The body of `createWorkspace`, with the whole read-then-act window inside it, so the queue
    /// above has one thing to hold rather than a sequence a caller could enter halfway through.
    private func cut(
        repo: Repo,
        prompt: String,
        name: String?,
        branch: String?,
        baseBranch: String?,
        origin: WorkspaceOrigin
    ) async throws -> Workspace {
        let settings = SettingsLoader.load(repo: repo.path)
        let base = baseBranch ?? repo.defaultBranch

        let existingBranches = Set(try await Git.branches(of: repo.path))
        let stem = Git.branchStem(prompt: prompt, prefix: settings.branchPrefix, branch: branch)
        let finalBranch = Git.uniqueBranch(stem, taken: existingBranches)

        let directoryName = finalBranch.replacingOccurrences(of: "/", with: "-")
        let root = Self.workspacesRoot.appendingPathComponent(repo.name, isDirectory: true)
        // The suffix rule lives in `WorktreePath` because restoring an archived workspace needs
        // the same one: two places that each invent a free directory name are two places that can
        // disagree about which names are free.
        let worktreePath = WorktreePath.free(
            preferred: root.appendingPathComponent(directoryName).path
        ) { FileManager.default.fileExists(atPath: $0) }

        try await Git.addWorktree(repo: repo.path, path: worktreePath, branch: finalBranch, base: base)

        try copyFiles(settings.filesToCopy, from: repo.path, to: worktreePath)

        // Naming `setupState` reaches the initialiser that is internal to the module, which is
        // why this can say it and nothing in `Sources/Bloom` can. A workspace with no setup script
        // to run is born `.skipped` rather than moved there: there is no run to file, and nothing
        // for `SetupLifecycle` to have done.
        let workspace = Workspace(
            repoID: repo.id,
            name: name ?? Git.title(from: prompt),
            branch: finalBranch,
            path: worktreePath,
            baseBranch: base,
            setupState: settings.setupScript == nil ? .skipped : .pending,
            sortOrder: try await store.nextWorkspaceSortOrder(repoID: repo.id),
            origin: origin
        )
        return try await store.upsert(workspace)
    }

    /// A worktree on a pull request or on a branch that already exists.
    ///
    /// The counterpart of `cut`, and everything different about it is in the first half. No branch
    /// is invented, no base is chosen and no name is derived: the head being opened supplies all
    /// three. Everything after the checkout is the same as for any other workspace, deliberately,
    /// because the whole point is that a review workspace is not a special kind of workspace. It
    /// gets the same copied files, the same setup script, the same row, and therefore the same
    /// diff viewer, terminal, checks view and agent.
    ///
    /// A pull request is fetched by `gh pr checkout` running inside the new worktree rather than
    /// by a fetch written here. See `GitHub.checkoutPullRequest` for why: a fork's head is not on
    /// `origin` at all, and every hand rolled version of this gets that case wrong.
    ///
    /// The worktree is removed again if the checkout fails, because a directory holding a detached
    /// HEAD and no pull request is worse than no directory: it would be registered with git,
    /// counted by `git worktree list`, and attached to no row anybody could archive.
    private func open(
        _ checkout: WorkspaceCheckout, repo: Repo, name: String?, origin: WorkspaceOrigin
    ) async throws -> Workspace {
        let settings = SettingsLoader.load(repo: repo.path)
        let existingBranches = Set(try await Git.branches(of: repo.path))
        let branch = WorkspaceCheckoutPlan.localBranch(for: checkout, taken: existingBranches)

        let directoryName = branch.replacingOccurrences(of: "/", with: "-")
        let root = Self.workspacesRoot.appendingPathComponent(repo.name, isDirectory: true)
        let worktreePath = WorktreePath.free(
            preferred: root.appendingPathComponent(directoryName).path
        ) { FileManager.default.fileExists(atPath: $0) }

        switch checkout {
        case .pullRequest(let request):
            try await Git.addDetachedWorktree(repo: repo.path, path: worktreePath)
            do {
                try await GitHub.checkoutPullRequest(
                    number: request.number, into: worktreePath, localBranch: branch
                )
            } catch {
                try? await Git.removeWorktree(repo: repo.path, path: worktreePath, force: true)
                throw error
            }
        case .branch(let existing) where existing.isLocal:
            try await Git.addWorktree(
                repo: repo.path, path: worktreePath, branch: existing.name, base: existing.name
            )
        case .branch(let existing):
            try await Git.addTrackingWorktree(
                repo: repo.path, path: worktreePath, branch: existing.name
            )
        }

        try copyFiles(settings.filesToCopy, from: repo.path, to: worktreePath)

        let workspace = Workspace(
            repoID: repo.id,
            name: name ?? checkout.workspaceName,
            branch: branch,
            path: worktreePath,
            baseBranch: checkout.baseBranch(default: repo.defaultBranch),
            setupState: settings.setupScript == nil ? .skipped : .pending,
            sortOrder: try await store.nextWorkspaceSortOrder(repoID: repo.id),
            origin: origin
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

    /// The prefix Bloom's own interface uses. Everything the app documents, and everything a
    /// script written for it should bind, is `BLOOM_*`.
    public static let environmentPrefix = "BLOOM"

    /// Kept alongside it, and deprecated.
    ///
    /// `CONDUCTOR_*` is not a second interface and nothing here should be read as Bloom being
    /// Conductor. It is compatibility: repositories whose committed setup scripts already say
    /// `$CONDUCTOR_ROOT_PATH` would otherwise break at setup time, with a shell error, in a file
    /// their team shares. Dropping it is a decision for the day those scripts have been moved
    /// over, not a rename anybody can do quietly.
    public static let deprecatedEnvironmentPrefix = "CONDUCTOR"

    public static let environmentPrefixes = [environmentPrefix, deprecatedEnvironmentPrefix]

    /// The project a workspace belongs to, as a name a script may put in an identifier.
    ///
    /// Conductor has no equivalent, so this one is Bloom's and the deprecated prefix carries it
    /// only so that the two prefixes stay the same set of names. It exists because
    /// `*_WORKSPACE_NAME` is unique inside one repository and nowhere else: two projects each
    /// with a branch called `main` produce the same name, so a setup script that says
    /// `CREATE DATABASE $BLOOM_WORKSPACE_NAME` has one project's worktree writing into the
    /// other's database, and the archive script then drops it out from under them. Every script
    /// author could derive this from `basename $BLOOM_ROOT_PATH`, and the ones who do not think
    /// of it are the ones the corruption happens to.
    ///
    /// Taken from the folder the repository is checked out in rather than from the project's
    /// display name, because the display name is renameable in the sidebar and a database named
    /// after it would be orphaned by a rename. Everything outside the ASCII letters, digits and
    /// underscores becomes an underscore, so the value can be pasted into a database name, a
    /// container name or a shell identifier without quoting.
    static func projectName(for repo: Repo) -> String {
        // A repository registered at the filesystem root has `/` as its last component, which
        // cleans down to a bare underscore, so the display name is the fallback for both that and
        // an empty path.
        let folder = URL(fileURLWithPath: repo.path).lastPathComponent
        let source = (folder.isEmpty || folder == "/") ? repo.name : folder
        let cleaned = String(source.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        })
        return cleaned.isEmpty ? "project" : cleaned
    }

    /// What a setup, archive or run script is launched with, on top of the user's own shell
    /// environment.
    ///
    /// One function for all three, so the three cannot drift into binding different names. The
    /// deprecated prefix carries exactly the same values as the real one, so a script written
    /// either way sees the same workspace.
    public func environment(for workspace: Workspace, repo: Repo, port: Int) -> [String: String] {
        let pairs: [(String, String)] = [
            ("IS_LOCAL", "1"),
            ("WORKSPACE_NAME", workspace.branch.replacingOccurrences(of: "/", with: "-")),
            ("WORKSPACE_ID", workspace.id.rawValue),
            ("WORKSPACE_PATH", workspace.path),
            ("PROJECT_NAME", Self.projectName(for: repo)),
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
    ///
    /// - Parameter onExit: the status the script ended on, reported once and only when one
    ///   exists. A run that never started a process has no status, and reporting a made up zero
    ///   for it would be worse than saying nothing: the transcript prints this number, and a
    ///   number a person can look up has to be the one the shell gave.
    @discardableResult
    public func runSetup(
        workspace: Workspace,
        repo: Repo,
        port: Int,
        onExit: (@Sendable (Int) -> Void)? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let settings = SettingsLoader.load(repo: repo.path)
        let launch = ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo.path
        )

        guard let launch else {
            _ = try? await store.update(workspaceID: workspace.id) { $0.apply(.runSkipped(note: nil)) }
            return true
        }

        switch launch {
        case .missing(let path):
            // Skipped, not failed. A settings file pointing at a script somebody deleted or has
            // not committed yet is not a reason to refuse them the worktree they asked for. It is
            // a reason to say so where they will see it, which is this workspace's setup log.
            let note = "The settings file names \(path) as the setup script and there is nothing "
                + "there, so nothing ran."
            onOutput(note)
            _ = try? await store.update(workspaceID: workspace.id) { $0.apply(.runSkipped(note: note)) }
            return true
        case .executable, .source:
            break
        }

        _ = try? await store.update(workspaceID: workspace.id) { $0.apply(.runStarted) }

        let env = environment(for: workspace, repo: repo, port: port)
        let runner = StreamingProcess(
            executable: launch.executable,
            arguments: launch.arguments,
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
        onExit?(Int(status))
        let succeeded = status == 0
        let printed = log
        // The whole `workspace` value here is as old as the run, and a run can take minutes, so
        // upserting it would clobber every other write to the row made in the meantime. `update`
        // re-reads inside the actor; `apply` writes the state and the log in one statement and
        // caps the log, so there is no shape of this that files an outcome without its output.
        _ = try? await store.update(workspaceID: workspace.id) {
            $0.apply(.runFinished(succeeded: succeeded, log: printed))
        }
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
        // Already archived, so there is nothing here to wind down. Everything below this line acts
        // on a worktree that has been removed once already: the archive script would run in a
        // directory that is gone, and `git branch -D` would take a branch whose only remaining
        // copy is on the remote. `WorkspaceState` has no transition table, for the reason written
        // in `WorkspaceLifecycle`, but this is the one edge that table would have had, so it is
        // written where the destructive work starts rather than where the row is finally saved.
        guard workspace.state == .active else { return }

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
        let archiveLaunch = ScriptLaunch.resolve(
            text: settings.archiveScript, file: settings.scriptFiles[.archive], repo: repo.path
        )
        // A `.missing` archive script is not run and does not stop the archive, for the same
        // reason a missing setup script does not stop a workspace being created.
        let archiveRuns: Bool
        switch archiveLaunch {
        case .executable, .source: archiveRuns = true
        case .missing, nil: archiveRuns = false
        }
        if let archiveLaunch, archiveRuns,
           FileManager.default.fileExists(atPath: workspace.path) {
            let env = environment(for: workspace, repo: repo, port: 0)
            let result = try await Shell.run(
                archiveLaunch.executable, archiveLaunch.arguments,
                cwd: workspace.path, env: env, timeout: .seconds(120)
            )
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

        // The two columns this method owns, and nothing else. The value handed in was read
        // before the safety report, the archive script, the worktree removal and the branch
        // delete, which on a real project is seconds; a rename or an automatic name landing in
        // that window used to be written back out of existence here.
        try await store.update(workspaceID: workspace.id) { $0.archive() }
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
