import Foundation

/// Making a project out of nothing: the folder, the repository in it, and the empty first commit
/// that lets a worktree be cut from it straight away.
///
/// It is a thin thing on purpose. `RepositoryStarter` already does everything from `git init`
/// onwards and does it carefully, so the only work here is the one step it cannot do, which is
/// creating a folder that is not there yet, plus knowing whether Bloom made that folder so that
/// abandoning the attempt can take it away again.
///
/// **The empty first commit is not a nicety.** `git worktree add` needs a branch and a branch needs
/// a commit, so a project registered without one is a project whose first workspace fails with
/// `projectHasNoCommits`. `RepositoryStarter.start` makes it with `--allow-empty`, and
/// `NewProjectStarterTests` holds the whole chain: create a project this way, and a worktree cuts
/// from it.
public enum NewProjectStarter {
    // MARK: - Looking

    /// What the file system says about the path a name and a location make, gathered so the
    /// verdict can stay pure.
    ///
    /// No subprocess in here, which is why it is synchronous. This runs while somebody is typing,
    /// once per keystroke after a pause, and a `git` process per keystroke is the version of this
    /// that gets noticed on a laptop. `Git.enclosingRepositoryRoot` walks up with `FileManager`
    /// for exactly the same reason.
    public static func inspect(
        name: String,
        location: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        workspacesRoot: String = WorkspaceManager.workspacesRoot.path
    ) -> NewProjectFacts {
        var facts = NewProjectFacts(
            name: name,
            location: location,
            homeDirectory: home,
            workspacesRoot: workspacesRoot
        )
        guard let path = NewProjectPlan.target(name: name, location: location, home: home) else {
            return facts
        }

        let manager = FileManager.default
        facts.path = path
        let parent = (path as NSString).deletingLastPathComponent

        var isDirectory: ObjCBool = false
        facts.locationExists = manager.fileExists(atPath: parent, isDirectory: &isDirectory)
            && isDirectory.boolValue

        isDirectory = false
        facts.targetExists = manager.fileExists(atPath: path, isDirectory: &isDirectory)
        facts.targetIsDirectory = facts.targetExists && isDirectory.boolValue
        if facts.targetIsDirectory {
            facts.targetIsRepository = manager.fileExists(
                atPath: (path as NSString).appendingPathComponent(".git")
            )
            facts.targetIsEmpty = isEmpty(path)
            facts.isTargetWritable = manager.isWritableFile(atPath: path)
            // One `fileExists` per child, so it is asked only where its answer is used: a folder
            // that is there, has something in it and is not itself a repository is the only shape
            // `FolderVerdict` asks it about. `~/dev/code` holds 293 of them on this Mac and the
            // question is put on every settled keystroke, which is why it is not asked of the
            // other three.
            if !facts.targetIsRepository, !facts.targetIsEmpty {
                facts.childRepositories = RepositoryStarter.childRepositories(of: path)
            }
        }

        facts.enclosingRepository = Git.enclosingRepositoryRoot(of: path)
        let ancestor = nearestExistingAncestor(of: path)
        facts.nearestExistingAncestor = ancestor
        facts.isAncestorWritable = manager.isWritableFile(atPath: ancestor)
        return facts
    }

    /// The same walk, from the one line the sheet has.
    ///
    /// Here rather than in the view for the reason the rest of this file is: resolving a name or a
    /// path and then looking at what is there are two halves of one answer, and a view that did
    /// the first half itself would be a view holding a rule.
    public static func inspect(
        typed: String,
        defaultLocation: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        workspacesRoot: String = WorkspaceManager.workspacesRoot.path
    ) -> NewProjectFacts {
        let target = ProjectTarget.resolve(typed, defaultLocation: defaultLocation, home: home)
        return inspect(
            name: target.name,
            location: target.location,
            home: home,
            workspacesRoot: workspacesRoot
        )
    }

    /// Whether a folder holds nothing worth keeping.
    ///
    /// `.DS_Store` is ignored, because the Finder writes one into any folder somebody has so much
    /// as looked at, and refusing a folder for holding one would refuse the empty folder a person
    /// had just made in the file panel to put this project in.
    ///
    /// **A folder that cannot be listed is not empty, it is unanswered.** This used to coalesce a
    /// failed read to `[]`, which `allSatisfy` calls empty, and `discard` reads empty as
    /// permission to `removeItem` the whole folder. That is the same shape as the hole
    /// `Git.safetyReport` throws over rather than returning zeroes for: an unasked question
    /// arriving as the answer that destroys something. False leaves the folder alone, which is
    /// what an unreadable folder deserves in both callers, since `inspect`'s verdict then treats
    /// it as a folder with something in it.
    static func isEmpty(_ path: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return entries.allSatisfy { $0 == ".DS_Store" }
    }

    /// The deepest folder above this path that exists, which is the one that has to be writable
    /// for `createDirectory` to make everything under it.
    static func nearestExistingAncestor(of path: String) -> String {
        var current = (FolderPath.normalize(path) as NSString).deletingLastPathComponent
        while current.count > 1, !FileManager.default.fileExists(atPath: current) {
            current = (current as NSString).deletingLastPathComponent
        }
        return current.isEmpty ? "/" : current
    }

    /// The branch the first commit will be on, asked of git rather than asserted.
    ///
    /// The sheet says the branch out loud, because a brand new repository's branch is a choice
    /// Bloom is about to make on somebody's behalf and an existing repository's is not. Saying
    /// "main" flatly would be a lie on a machine with `init.defaultBranch` set, and the person who
    /// set it is exactly the person who would notice.
    ///
    /// Asked in the home directory, which is where the global config is read from and which is
    /// always there. There is no repository yet to ask in.
    public static func plannedBranch(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> String {
        let configured = try? await Git.run(["config", "--get", "init.defaultBranch"], in: home)
        guard let configured, configured.ok else { return "main" }
        let preference = configured.trimmed
        return preference.isEmpty ? "main" : preference
    }

    // MARK: - Doing

    /// Makes the folder if it is not there, then runs the local half of `RepositoryStarter`.
    ///
    /// - Parameter progress: the steps, passed straight through, so the sheet can say which one it
    ///   is on. There are only two for a local repository and they are quick, but a signing helper
    ///   can stall the commit for as long as it likes, which is the bug `ProjectSetupSheet`'s
    ///   patience timer was written for.
    public static func create(
        at path: String,
        progress: @Sendable @MainActor (RepositoryStartStep) -> Void = { _ in }
    ) async throws -> NewProjectCreation {
        let folder = FolderPath.normalize((path as NSString).expandingTildeInPath)
        var created = false

        if !FileManager.default.fileExists(atPath: folder) {
            do {
                try FileManager.default.createDirectory(
                    atPath: folder, withIntermediateDirectories: true
                )
                created = true
            } catch {
                throw NewProjectFailure(
                    title: "Could not create the folder",
                    message: RepositoryStarter.sentence(from: error),
                    folderWasCreated: false
                )
            }
        }

        do {
            let outcome = try await RepositoryStarter.start(
                at: folder, destination: .local, progress: progress
            )
            return NewProjectCreation(
                path: folder, branch: outcome.branch, folderWasCreated: created
            )
        } catch let failure as RepositoryStartFailure {
            throw NewProjectFailure(
                title: failure.title, message: failure.message, folderWasCreated: created
            )
        } catch {
            throw NewProjectFailure(
                title: "Could not create the repository",
                message: RepositoryStarter.sentence(from: error),
                folderWasCreated: created
            )
        }
    }

    /// Undoes exactly what Bloom made, and nothing else.
    ///
    /// The repository half is `RepositoryStarter.abandon`, which keeps a folder the moment there
    /// is a commit in it because that commit holds somebody's files. The folder half follows the
    /// same rule one level up: Bloom removes the folder only if Bloom made it, only if the
    /// repository went with it, and only if nothing has appeared in it in the meantime. A person
    /// who dropped a file into the new folder while the dialog was up keeps their file.
    @discardableResult
    public static func discard(
        at path: String, folderWasCreated: Bool
    ) async -> NewProjectAbandonment {
        let folder = FolderPath.normalize((path as NSString).expandingTildeInPath)
        let repository = await RepositoryStarter.abandon(at: folder)

        guard folderWasCreated, repository != .projectKept, isEmpty(folder) else {
            return NewProjectAbandonment(repository: repository, folderRemoved: false)
        }
        let removed = (try? FileManager.default.removeItem(atPath: folder)) != nil
        return NewProjectAbandonment(repository: repository, folderRemoved: removed)
    }
}

/// A project that was made, and enough to register it and to undo it.
public struct NewProjectCreation: Sendable, Equatable {
    public var path: String
    public var branch: String
    /// Whether the folder itself is Bloom's doing. False when the person pointed at an empty
    /// folder that was already there, which is the one case where abandoning must leave it.
    public var folderWasCreated: Bool

    public init(path: String, branch: String, folderWasCreated: Bool) {
        self.path = path
        self.branch = branch
        self.folderWasCreated = folderWasCreated
    }
}

/// A creation that did not work, in the voice `RepositoryStartFailure` set: what could not be
/// done, what the tool said, and enough to put the disk back.
public struct NewProjectFailure: Error, Sendable, Equatable {
    public var title: String
    public var message: String
    public var folderWasCreated: Bool

    public init(title: String, message: String, folderWasCreated: Bool) {
        self.title = title
        self.message = message
        self.folderWasCreated = folderWasCreated
    }
}

/// What is on disk after a new project was abandoned.
///
/// Two facts rather than one, because they are undone by two different rules and either can hold
/// without the other: a folder Bloom did not make keeps its `git init` undone and stays, and a
/// folder Bloom made that now has a commit in it stays with the repository intact.
public struct NewProjectAbandonment: Sendable, Equatable {
    public var repository: RepositoryStartAbandonment
    public var folderRemoved: Bool

    public init(repository: RepositoryStartAbandonment, folderRemoved: Bool) {
        self.repository = repository
        self.folderRemoved = folderRemoved
    }

    /// Whether what is left is a project Bloom could still run, which is what makes "add it
    /// anyway" an honest offer after a failure.
    public var isUsableProject: Bool { repository.isUsableProject }

    /// What is on disk now, said in the same voice as `RepositoryStartAbandonment.state`.
    public var state: String {
        if folderRemoved {
            return "Bloom removed the folder it had just made, so nothing is left on disk."
        }
        return repository.state
    }
}
