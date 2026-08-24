import Foundation

/// Where a new repository should end up.
public enum RepositoryDestination: Sendable, Equatable {
    /// `git init` and a first commit. No network, no account, no gh. Everything Bloom does with a
    /// project (worktrees, agents, diffs, merging back into the base branch) works here. Only pull
    /// requests and checks need the other case.
    case local
    case gitHub(owner: String, name: String, isPrivate: Bool)

    public var isGitHub: Bool {
        if case .gitHub = self { return true }
        return false
    }

    /// `owner/name`, for a sentence that has to name what will be created.
    public var slug: String? {
        guard case .gitHub(let owner, let name, _) = self else { return nil }
        return "\(owner)/\(name)"
    }
}

/// The sequence, in order. Named individually because every one of them fails differently and
/// leaves the folder in a different state.
public enum RepositoryStartStep: String, Sendable, CaseIterable, Comparable {
    case initialise
    case commit
    case createRemoteRepository
    case addOrigin
    case push

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// Present tense, because it is shown while the step is running.
    public var label: String {
        switch self {
        case .initialise: "Creating the repository"
        case .commit: "Making the first commit"
        case .createRemoteRepository: "Creating the repository on GitHub"
        case .addOrigin: "Adding origin"
        case .push: "Pushing"
        }
    }

    public static func steps(for destination: RepositoryDestination) -> [RepositoryStartStep] {
        destination.isGitHub ? allCases : [.initialise, .commit]
    }

    /// How long this step is given before the dialog says out loud that it has not finished.
    ///
    /// Not a deadline. Nothing here is cancelled when the time is up: the step is still running
    /// and may still succeed, and killing a push two minutes into somebody's first upload would
    /// be worse than the silence it replaced. What runs out is Bloom's willingness to keep
    /// claiming that everything is fine.
    ///
    /// The numbers are generous multiples of what each step really costs, because the point is to
    /// catch a step that has stopped rather than one that is slow. `git init` and `git remote add`
    /// are local and instant. The commit is the one that hangs in practice, and it hangs on
    /// something outside git: a signing helper waiting on an approval that never appeared. The
    /// push is legitimately long, so it is given three minutes before anything is said, and what
    /// is said about it is not alarming.
    public var patience: Duration {
        switch self {
        case .initialise: .seconds(15)
        case .commit: .seconds(20)
        case .createRemoteRepository: .seconds(30)
        case .addOrigin: .seconds(15)
        case .push: .seconds(180)
        }
    }

    /// What to say once `patience` has run out. It names the command, because that is what a
    /// person needs in order to go and look at it, and it names the likeliest cause.
    public var slowNotice: String {
        switch self {
        case .initialise:
            """
            git init has not come back. It is normally instant, so something outside git is \
            holding it up. You can stop and try again.
            """
        case .commit:
            """
            git commit has not come back. The usual cause is commit signing: a key, a smart card \
            or a helper such as 1Password is waiting for an approval, and the prompt can be \
            behind another window or missing altogether. Look for it, or stop and try again.
            """
        case .createRemoteRepository:
            """
            gh has not answered. It may be waiting on the network, or on a login that has to be \
            finished in a browser. You can stop and try again.
            """
        case .addOrigin:
            """
            git remote add has not come back, which is a local command that should be instant. \
            You can stop and try again.
            """
        case .push:
            """
            Still uploading. A first push of a large folder takes a while, so this is not \
            necessarily wrong. Stopping now leaves the commit here and nothing on GitHub.
            """
        }
    }
}

/// What was left behind when a start was stopped part way through.
///
/// Stopping is not the same as failing, and it needs its own answer for the same reason
/// `RepositoryStartFailure.state` exists: a person who has just abandoned a dialog has to be told
/// what is now on their disk. The difference is that a stop can also UNDO something, which a
/// failure never does.
///
/// The rule is that Bloom cleans up exactly what it made and nothing else. A `git init` with no
/// commit after it is a folder that is a repository and cannot be used as one: Bloom cannot cut a
/// worktree from it, git tools behave differently inside it, and nobody asked for it. So it goes.
/// The moment there is a commit it stops being Bloom's to remove: that commit holds the user's
/// files, it is a project Bloom can run, and deleting it would be throwing away the only half of
/// the job that worked.
public enum RepositoryStartAbandonment: Sendable, Equatable {
    /// No repository was made, so there is nothing to undo.
    case nothingToUndo
    /// The `git init` Bloom ran was undone. The folder is a plain folder again.
    case repositoryRemoved
    /// There is a commit, so the folder is a project Bloom can run and it is left exactly as it is.
    case projectKept

    /// Pure, and the whole decision.
    ///
    /// - Parameter hasGitDirectory: whether a `.git` sits directly in this folder. Deliberately
    ///   not "is a repository", which git also answers yes to for a folder inside somebody else's
    ///   checkout, and which would make this remove a `.git` belonging to a repository further up
    ///   the tree.
    public static func decide(hasGitDirectory: Bool, hasCommits: Bool) -> Self {
        guard hasGitDirectory else { return .nothingToUndo }
        return hasCommits ? .projectKept : .repositoryRemoved
    }

    /// Whether the folder is a repository Bloom can already run workspaces in, which is what makes
    /// "add the project anyway" an honest offer after a stop.
    public var isUsableProject: Bool { self == .projectKept }

    /// What the folder is now, in the same voice as `RepositoryStartFailure.state`.
    public var state: String {
        switch self {
        case .nothingToUndo:
            "Nothing was changed. The folder is exactly as it was."
        case .repositoryRemoved:
            """
            The repository Bloom had started making was removed again, so the folder is exactly \
            as it was. Anything the run had already written to .gitignore is still there.
            """
        case .projectKept:
            """
            The folder is a git repository and your files are in its first commit, so Bloom can \
            run workspaces in it. Nothing was sent to GitHub.
            """
        }
    }
}

/// What actually happened, once all of it worked.
public struct RepositoryStartOutcome: Sendable, Equatable {
    public var branch: String
    public var committedFiles: Int
    /// What was deliberately left out of the first commit, and written into `.gitignore`.
    public var excluded: [ExcludedPath]
    /// The commit had to be made without a signature. See `Git.commit`.
    public var commitWasUnsigned: Bool
    public var remoteURL: String?
    public var page: String?

    public init(
        branch: String,
        committedFiles: Int,
        excluded: [ExcludedPath] = [],
        commitWasUnsigned: Bool = false,
        remoteURL: String? = nil,
        page: String? = nil
    ) {
        self.branch = branch
        self.committedFiles = committedFiles
        self.excluded = excluded
        self.commitWasUnsigned = commitWasUnsigned
        self.remoteURL = remoteURL
        self.page = page
    }
}

/// A step that did not work, and the exact state it left behind.
///
/// The state sentence is the point of this type. Five things happen in order and any of them can
/// fail, so "could not create the repository" is never enough: the user has to know whether their
/// folder is untouched, is a repository with no commits, or is a repository whose contents are now
/// sitting on GitHub. Every one of those needs a different next action.
public struct RepositoryStartFailure: Error, Sendable, Equatable {
    public var step: RepositoryStartStep
    /// What git or gh said, trimmed to something readable.
    public var message: String
    public var completed: Set<RepositoryStartStep>
    public var destination: RepositoryDestination
    /// The branch, once there is one.
    public var branch: String?

    public init(
        step: RepositoryStartStep,
        message: String,
        completed: Set<RepositoryStartStep>,
        destination: RepositoryDestination,
        branch: String? = nil
    ) {
        self.step = step
        self.message = message
        self.completed = completed
        self.destination = destination
        self.branch = branch
    }

    /// Whether the folder is a repository Bloom can already run workspaces in. True the moment
    /// there is a commit, which is what makes "add the project anyway" an honest offer after a
    /// GitHub failure rather than a way to add a project that cannot make a worktree.
    public var isUsableProject: Bool {
        completed.contains(.initialise) && completed.contains(.commit)
    }

    /// What the folder is now. Written from the steps that did finish, not from the one that did
    /// not, so it stays true whichever way the sequence was entered.
    public var state: String {
        let slug = destination.slug ?? "the repository"

        if !completed.contains(.initialise) {
            return "Nothing was changed. The folder is exactly as it was."
        }
        if !completed.contains(.commit) {
            return """
            The folder is now a git repository, and it has no commits. Bloom cannot create a \
            workspace until it has one, because a worktree needs a branch to start from.
            """
        }
        if !completed.contains(.createRemoteRepository) {
            return """
            The folder is a git repository and your files are in its first commit. Nothing was \
            sent to GitHub, and no repository was created there.
            """
        }
        if !completed.contains(.addOrigin) {
            return """
            The folder is a git repository and your files are in its first commit. \(slug) was \
            created on GitHub and is empty. The folder has no origin yet, so nothing has been \
            uploaded.
            """
        }
        return """
        The folder is a git repository and your files are in its first commit. \(slug) was created \
        on GitHub and is empty, and origin points at it. Nothing has been uploaded.
        """
    }

    /// The heading. Short, and it names the step rather than the tool.
    public var title: String {
        switch step {
        case .initialise: "Could not create the repository"
        case .commit: "Could not make the first commit"
        case .createRemoteRepository: "Could not create the repository on GitHub"
        case .addOrigin: "Could not add origin"
        case .push: "Could not push"
        }
    }
}

/// Everything that touches the disk on the way from "a folder" to "a project".
///
/// The decisions this carries out are in `RepositoryStartPlan`, which is pure and tested. What is
/// here is the order things happen in and what happens when one of them does not.
public enum RepositoryStarter {
    /// The message on the first commit.
    ///
    /// "Initial commit" and nothing else, deliberately. Bloom has not read this code and cannot
    /// say what it does, and a generated sentence describing somebody's project would be a claim
    /// about work Bloom did not do, permanently attached to their history by an author who is
    /// them. It is also what GitHub itself writes, so it reads as a convention rather than as
    /// something an app decided.
    public static let commitMessage = "Initial commit"

    /// Enough files that the walk stops and says so rather than counting a `node_modules` for a
    /// minute while somebody waits on a dialog.
    public static let walkLimit = 50_000

    // MARK: - Looking

    /// What git and the file system say about a folder, gathered in one place so the verdict can
    /// stay pure.
    public static func inspect(
        _ path: String,
        workspacesRoot: String = WorkspaceManager.workspacesRoot.path,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> FolderFacts {
        let manager = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        let normalized = FolderPath.normalize(expanded)

        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: normalized, isDirectory: &isDirectory)

        // Asked only of a folder that is there. `Git.isRepository` answers false for a missing
        // path anyway, because the process cannot be launched in it, so this is a subprocess
        // saved rather than an answer changed.
        var isRepository = false
        if exists, isDirectory.boolValue { isRepository = await Git.isRepository(normalized) }

        // Asked only of a repository, because it is the only branch of the verdict that reads it
        // and because it is a subprocess. Nil from a repository that will not answer falls back
        // to the path, which is what the rule used before this was gathered at all.
        var repositoryRoot: String?
        if isRepository { repositoryRoot = try? await Git.topLevel(of: normalized) }

        return FolderFacts(
            path: normalized,
            isRepository: isRepository,
            repositoryRoot: repositoryRoot,
            enclosingRepository: isRepository ? nil : Git.enclosingRepositoryRoot(of: normalized),
            isWritable: manager.isWritableFile(atPath: normalized),
            isDirectory: exists && isDirectory.boolValue,
            exists: exists,
            // The tilde is expanded above, so a path that started with one counts as absolute.
            // It is the caller's home either way: the bridge runs on this machine.
            isAbsolute: expanded.hasPrefix("/"),
            homeDirectory: home,
            workspacesRoot: workspacesRoot,
            childRepositories: childRepositories(of: normalized)
        )
    }

    /// Direct children that are repositories in their own right. Only one level down: this is
    /// asking "is this a folder of projects", and a folder of projects wears it on the surface.
    static func childRepositories(of path: String) -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: path) else { return [] }
        return entries.filter { name in
            let child = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: child, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return manager.fileExists(atPath: (child as NSString).appendingPathComponent(".git"))
        }.sorted()
    }

    /// What a first commit would contain.
    ///
    /// A plain walk of the folder, not git's own answer, because there is no repository yet to
    /// ask. That makes the file count an upper bound whenever a `.gitignore` already exists, and
    /// `FolderContents.summary` says "at most" for exactly that reason. Erring high is the safe
    /// direction: a dialog that under-promised how much would be published would be the dangerous
    /// one.
    public static func scan(_ path: String) -> FolderContents {
        let root = FolderPath.normalize(path)
        let manager = FileManager.default
        var contents = FolderContents()
        contents.hasGitignore = manager.fileExists(
            atPath: (root as NSString).appendingPathComponent(".gitignore")
        )

        // The path based enumerator, not the URL one, and for one specific reason: it hands back
        // paths relative to the folder, already. The URL enumerator returns absolute URLs with
        // every symlink resolved, so a folder under `/tmp` comes back spelled `/private/tmp/...`
        // and no amount of prefix matching against the path that was asked about lines the two
        // up. That failure was silent. The walk found nothing, the dialog reported an empty
        // folder, and the credentials it exists to keep out were committed.
        guard let walker = manager.enumerator(atPath: root) else { return contents }

        var seen = 0
        while let relative = walker.nextObject() as? String {
            seen += 1
            if seen > walkLimit {
                contents.truncated = true
                break
            }

            let attributes = walker.fileAttributes
            let full = (root as NSString).appendingPathComponent(relative)

            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                // This runs again after `git init`, so the repository's own administrative
                // directory has to be stepped over. Walking into it would count several hundred
                // files nobody committed and read its packed objects as content.
                if (relative as NSString).lastPathComponent == ".git" {
                    walker.skipDescendants()
                    continue
                }
                // A directory with its own `.git` is somebody else's repository. Committed as it
                // stands it becomes a gitlink with no submodule behind it, which every worktree
                // then checks out as an empty folder.
                if manager.fileExists(atPath: (full as NSString).appendingPathComponent(".git")) {
                    contents.excluded.append(ExcludedPath(path: relative, reason: .nestedRepository))
                    walker.skipDescendants()
                }
                continue
            }

            // The link file a worktree keeps where its `.git` directory would be.
            if (relative as NSString).lastPathComponent == ".git" { continue }

            if SensitiveFile.matches(relative) {
                contents.excluded.append(ExcludedPath(path: relative, reason: .sensitive))
                continue
            }

            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            contents.fileCount += 1
            contents.byteSize += size
            if size >= FolderContents.oversizeLimit { contents.oversizeFiles.append(relative) }
        }
        return contents
    }

    /// The identity git would sign the commit with, or the sentence to show instead.
    ///
    /// Checked before the dialog offers its button rather than caught afterwards. A commit with no
    /// `user.email` fails with a screenful of advice, and it fails after `git init` has already
    /// run, which is the one half-finished state worth designing out entirely.
    public static func identityProblem(at path: String) async -> String? {
        let identity = await Git.commitIdentity(in: path)
        guard identity.name == nil || identity.email == nil else { return nil }
        return """
        Git does not know who you are on this Mac, so it cannot make a commit. Set a name and an \
        address with git config --global user.name and git config --global user.email, then try \
        again.
        """
    }

    // MARK: - Doing

    /// Runs the sequence and reports which step it is on.
    ///
    /// - Parameter completed: steps a previous attempt already finished. Passing the set from a
    ///   `RepositoryStartFailure` resumes where it stopped, which is what makes "try again" after
    ///   a failed push a push rather than a second attempt to create a repository that now exists.
    @discardableResult
    public static func start(
        at path: String,
        destination: RepositoryDestination,
        completed: Set<RepositoryStartStep> = [],
        progress: @Sendable @MainActor (RepositoryStartStep) -> Void = { _ in }
    ) async throws -> RepositoryStartOutcome {
        let folder = FolderPath.normalize((path as NSString).expandingTildeInPath)
        var done = completed
        var branch = ""
        var excluded: [ExcludedPath] = []
        var committedFiles = 0
        var unsigned = false

        func fail(_ step: RepositoryStartStep, _ error: Error) -> RepositoryStartFailure {
            RepositoryStartFailure(
                step: step,
                message: sentence(from: error),
                completed: done,
                destination: destination,
                branch: branch.isEmpty ? nil : branch
            )
        }

        // 1. The repository itself.
        if done.contains(.initialise) {
            branch = (try? await Git.check(["symbolic-ref", "--short", "HEAD"], in: folder).trimmed)
                ?? "main"
        } else {
            await progress(.initialise)
            do {
                branch = try await Git.initRepository(at: folder)
            } catch {
                throw fail(.initialise, error)
            }
            done.insert(.initialise)
        }

        // 2. The first commit, without which no worktree can be cut.
        if await Git.hasCommits(in: folder) {
            done.insert(.commit)
            committedFiles = (try? await Git.stagedPaths(in: folder).count) ?? 0
        } else {
            await progress(.commit)
            do {
                (committedFiles, excluded, unsigned) = try await makeFirstCommit(in: folder)
            } catch {
                throw fail(.commit, error)
            }
            done.insert(.commit)
        }

        guard case .gitHub(let owner, let name, let isPrivate) = destination else {
            return RepositoryStartOutcome(
                branch: branch,
                committedFiles: committedFiles,
                excluded: excluded,
                commitWasUnsigned: unsigned
            )
        }

        // An origin that is already set is proof that both of the next two steps have run: Bloom
        // only ever points origin at a repository it has just created. Without this, a retry after
        // a failed push would try to create the repository a second time and be told, correctly,
        // that the name is taken.
        if let existing = await Git.remoteURL("origin", in: folder), !existing.isEmpty {
            done.insert(.createRemoteRepository)
            done.insert(.addOrigin)
        }

        // 3. The repository on GitHub. Empty: nothing is uploaded by this step.
        var url = await GitHub.remoteURL(owner: owner, name: name)
        if !done.contains(.createRemoteRepository) {
            await progress(.createRemoteRepository)
            do {
                url = try await GitHub.createRepository(
                    owner: owner, name: name, isPrivate: isPrivate
                )
            } catch {
                throw fail(.createRemoteRepository, error)
            }
            done.insert(.createRemoteRepository)
        }

        // 4. origin.
        if !done.contains(.addOrigin) {
            await progress(.addOrigin)
            do {
                if await Git.remoteURL("origin", in: folder) == nil {
                    try await Git.addRemote("origin", url: url, in: folder)
                }
            } catch {
                throw fail(.addOrigin, error)
            }
            done.insert(.addOrigin)
        }

        // 5. The upload. The first moment any of the folder's contents leaves this Mac.
        if !done.contains(.push) {
            await progress(.push)
            do {
                try await GitHub.push(
                    worktree: folder, branch: branch, setUpstream: true, timeout: .seconds(600)
                )
            } catch {
                throw fail(.push, error)
            }
            done.insert(.push)
        }

        return RepositoryStartOutcome(
            branch: branch,
            committedFiles: committedFiles,
            excluded: excluded,
            commitWasUnsigned: unsigned,
            remoteURL: url,
            page: GitHub.repositoryPage(owner: owner, name: name)
        )
    }

    /// Undoes a start that was stopped part way through, and says what is left.
    ///
    /// Only ever correct for a folder Bloom itself initialised, which is the only kind the setup
    /// dialog is offered for: `FolderVerdict.of` refuses a folder that already is a repository and
    /// refuses one that sits inside another, so a `.git` here is one this run made. Called from a
    /// fresh task rather than from the cancelled one, because a cancelled task's subprocesses
    /// refuse to start.
    ///
    /// Deliberately does NOT touch a remote. A repository created on GitHub is a thing that exists
    /// in somebody's account, under their name, and an app deleting one because a dialog was
    /// closed is not a cleanup. The state sentence says it is there instead.
    @discardableResult
    public static func abandon(at path: String) async -> RepositoryStartAbandonment {
        let folder = FolderPath.normalize((path as NSString).expandingTildeInPath)
        let gitDirectory = (folder as NSString).appendingPathComponent(".git")
        let hasGitDirectory = FileManager.default.fileExists(atPath: gitDirectory)

        let hasCommits = hasGitDirectory ? await Git.hasCommits(in: folder) : false
        let outcome = RepositoryStartAbandonment.decide(
            hasGitDirectory: hasGitDirectory, hasCommits: hasCommits
        )
        if outcome == .repositoryRemoved {
            try? FileManager.default.removeItem(atPath: gitDirectory)
        }
        return outcome
    }

    /// Stages the folder, keeps the credentials out, and commits.
    ///
    /// The exclusion happens twice on purpose. `.gitignore` is written first so the files stay out
    /// of every future commit as well, and the index is then read back and anything that got in
    /// anyway is removed from it. The second pass is the one that matters: a `.gitignore` rule can
    /// be overridden by a negation elsewhere in the file, and the cost of being wrong here is a
    /// private key in a commit that is about to be pushed.
    private static func makeFirstCommit(
        in folder: String
    ) async throws -> (files: Int, excluded: [ExcludedPath], unsigned: Bool) {
        let contents = scan(folder)

        var written: [ExcludedPath] = []
        for candidate in contents.excluded {
            // Already covered by a `.gitignore` the user wrote. Adding a duplicate line would be
            // Bloom editing a file it had no reason to touch.
            if await Git.isIgnored(candidate.path, in: folder) { continue }
            written.append(candidate)
        }
        if !written.isEmpty { try appendGitignore(written, in: folder) }

        try await Git.stageAll(in: folder)

        let staged = try await Git.stagedPaths(in: folder)
        let forbidden = Set(contents.excluded.map(\.path))
        let leaked = staged.filter { path in
            forbidden.contains(path) || forbidden.contains { path.hasPrefix($0 + "/") }
        }
        if !leaked.isEmpty {
            try await Git.unstage(leaked, in: folder)
        }

        let remaining = try await Git.stagedPaths(in: folder)
        // An empty folder gets an empty first commit. That is a real commit with a real tree, it
        // is what `git commit --allow-empty` exists for, and it gives the branch something for
        // `git worktree add` to start from.
        let unsigned = try await Git.commit(
            message: commitMessage, in: folder, allowEmpty: remaining.isEmpty
        )
        return (remaining.count, contents.excluded, unsigned)
    }

    /// Appends to `.gitignore`, creating it when there is none. Never rewrites what is there.
    static func appendGitignore(_ paths: [ExcludedPath], in folder: String) throws {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        var block = ""
        if !existing.isEmpty && !existing.hasSuffix("\n") { block += "\n" }
        if !existing.isEmpty { block += "\n" }
        block += "# Added by Bloom when this folder became a repository.\n"

        let secrets = paths.filter { $0.reason == .sensitive }
        let repositories = paths.filter { $0.reason == .nestedRepository }
        if !secrets.isEmpty {
            block += "# These look like they hold credentials, so they are not committed.\n"
            block += secrets.map(\.gitignoreLine).joined(separator: "\n") + "\n"
        }
        if !repositories.isEmpty {
            block += "# These are git repositories of their own.\n"
            block += repositories.map(\.gitignoreLine).joined(separator: "\n") + "\n"
        }

        try (existing + block).write(to: url, atomically: true, encoding: .utf8)
    }

    /// One readable line out of whatever git or gh returned.
    ///
    /// Public because `ProjectSetupSheet`'s untyped catch needs it: `readableMessage` there is
    /// the argv and the exit status, in the same modal this method exists to keep them out of.
    public static func sentence(from error: Error) -> String {
        let raw: String
        if let shell = error as? ShellError {
            raw = shell.stderr.isEmpty ? shell.description : shell.stderr
        } else {
            raw = error.readableMessage
        }

        let lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") && !$0.hasPrefix("Usage:") }
        guard let first = lines.first else { return "It did not say why." }
        return first.count > 300 ? String(first.prefix(300)) + "..." : first
    }
}
