import Testing
import Foundation
@testable import BloomCore

/// Real git against throwaway directories. Nothing here touches GitHub: every test uses the
/// `.local` destination, which is the whole point of that case existing.
/// Whether inspecting `path` comes out as "register the repository at `root`". Compared with
/// symlinks resolved on both sides, because git answers with the real directory and the scratch
/// folder these tests work in is reached through `/tmp`, which is a symlink.
private func registers(_ path: String, as root: String) async -> Bool {
    guard case .alreadyRepository(let registered) = await FolderVerdict.of(
        RepositoryStarter.inspect(path)
    ) else { return false }
    return FolderPath.resolved(registered) == FolderPath.resolved(root)
}

@Suite("Starting a repository", .tags(.git), .scratchDirectory)
struct RepositoryStarterTests {
    /// A folder in the running test's scratch directory, with the given files in it.
    private func folder(_ files: [String: String] = [:]) throws -> String {
        let root = TestScratch.unique("bloom-start")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for (relative, contents) in files {
            let full = (root as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// git will not commit without a name and an address, and this machine's git is the one
    /// making the commit. Every test that commits says so rather than failing obscurely.
    private func hasIdentity() async -> Bool {
        await RepositoryStarter.identityProblem(at: NSTemporaryDirectory()) == nil
    }

    private func committedPaths(in repo: String) async throws -> [String] {
        try await Git.check(["ls-tree", "-r", "--name-only", "HEAD"], in: repo).lines
    }

    // MARK: - Looking

    @Test("a plain folder is offered, and git's own answer wins when it is a repository")
    func inspection() async throws {
        let plain = try folder(["README.md": "hi"])
        let facts = await RepositoryStarter.inspect(plain)
        #expect(facts.isRepository == false)
        #expect(facts.isDirectory)
        #expect(facts.isWritable)
        #expect(FolderVerdict.of(facts) == .offer)

        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        #expect(await registers(repo.path, as: repo.path))
    }

    @Test("a folder inside a repository is spotted by walking up as well as by asking git")
    func nestedFolder() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("nested/deep/file.txt", "x")

        let inner = (repo.path as NSString).appendingPathComponent("nested/deep")
        #expect(Git.enclosingRepositoryRoot(of: inner) != nil)
        // git claims the whole work tree, so this folder never reaches the offer in the first
        // place. The walk is the second line of defence for the cases git declines to claim.
        #expect(await registers(inner, as: repo.path))
    }

    @Test("a folder full of repositories is recognised as a folder of projects")
    func containerOfProjects() async throws {
        let root = try folder()
        for name in ["one", "two", "three"] {
            let child = (root as NSString).appendingPathComponent(name)
            try FileManager.default.createDirectory(atPath: child, withIntermediateDirectories: true)
            try await Shell.check("git", ["init", "-q"], cwd: child)
        }
        #expect(RepositoryStarter.childRepositories(of: root) == ["one", "three", "two"])

        let facts = await RepositoryStarter.inspect(root)
        #expect(FolderVerdict.of(facts) == .refuse(.containerOfProjects(["one", "three", "two"])))
    }

    // MARK: - Scanning

    @Test("the scan separates what is committed from what is kept out")
    func scanning() async throws {
        let root = try folder([
            "README.md": "hello",
            "src/main.swift": "print(1)",
            ".env": "SECRET=1",
            ".env.example": "SECRET=",
            "certs/server.pem": "-----BEGIN",
        ])
        let nested = (root as NSString).appendingPathComponent("vendor/pkg")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q"], cwd: nested)
        try "noise".write(
            toFile: (nested as NSString).appendingPathComponent("ignored.txt"),
            atomically: true, encoding: .utf8
        )

        let contents = RepositoryStarter.scan(root)
        #expect(contents.sensitiveFiles.sorted() == [".env", "certs/server.pem"])
        #expect(contents.nestedRepositories == ["vendor/pkg"])
        // README, .env.example and src/main.swift. Nothing from inside the nested repository:
        // the walk stops at its edge, so its file count never inflates the promise.
        #expect(contents.fileCount == 3)
        #expect(contents.byteSize > 0)
        #expect(contents.truncated == false)
        #expect(contents.hasGitignore == false)
    }

    // MARK: - The sequence

    @Test("an empty folder gets a repository with an empty first commit a worktree can start from")
    func emptyFolder() async throws {
        guard await hasIdentity() else { return }
        let root = try folder()

        let outcome = try await RepositoryStarter.start(at: root, destination: .local)
        #expect(outcome.committedFiles == 0)
        #expect(outcome.remoteURL == nil)
        #expect(await Git.isRepository(root))
        #expect(await Git.hasCommits(in: root))
        #expect(try await committedPaths(in: root).isEmpty)

        // The reason the commit exists at all. `git worktree add` needs a branch, and a branch
        // needs a commit, so without this the flow would report success and the first workspace
        // would fail.
        let worktree = TestScratch.unique("worktree")
        try await Git.addWorktree(repo: root, path: worktree, branch: "bloom/test", base: outcome.branch)
        #expect(FileManager.default.fileExists(atPath: worktree))
        try await Git.removeWorktree(repo: root, path: worktree, force: true)
    }

    @Test("the folder's contents are committed so a worktree is not empty")
    func commitsContents() async throws {
        guard await hasIdentity() else { return }
        let root = try folder(["README.md": "hello", "src/main.swift": "print(1)"])

        let outcome = try await RepositoryStarter.start(at: root, destination: .local)
        #expect(outcome.committedFiles == 2)
        #expect(try await committedPaths(in: root).sorted() == ["README.md", "src/main.swift"])

        let worktree = TestScratch.unique("worktree")
        try await Git.addWorktree(repo: root, path: worktree, branch: "bloom/test", base: outcome.branch)
        #expect(FileManager.default.fileExists(
            atPath: (worktree as NSString).appendingPathComponent("src/main.swift")
        ))
        try await Git.removeWorktree(repo: root, path: worktree, force: true)
    }

    /// The one that matters. A `.env` in the first commit of a repository that is about to be
    /// pushed is a published secret, and it is published by an action the user took for an
    /// unrelated reason.
    @Test("credentials stay out of the first commit and out of every later one")
    func keepsSecretsOut() async throws {
        guard await hasIdentity() else { return }
        let root = try folder([
            "README.md": "hello",
            ".env": "APP_KEY=base64:hunter2",
            ".env.example": "APP_KEY=",
            "deploy/id_rsa": "-----BEGIN OPENSSH PRIVATE KEY-----",
        ])

        let outcome = try await RepositoryStarter.start(at: root, destination: .local)
        let committed = try await committedPaths(in: root)
        #expect(committed.contains(".env") == false)
        #expect(committed.contains("deploy/id_rsa") == false)
        // The example file is documentation, not a credential, and is committed.
        #expect(committed.contains(".env.example"))
        #expect(committed.contains(".gitignore"))
        #expect(outcome.excluded.map(\.path).sorted() == [".env", "deploy/id_rsa"])

        // Still ignored afterwards, so the next `git add -A` the user runs cannot undo this.
        #expect(await Git.isIgnored(".env", in: root))
        #expect(await Git.isIgnored("deploy/id_rsa", in: root))
        #expect(await Git.isIgnored(".env.example", in: root) == false)

        // And the files are still on disk. Bloom excludes them, it does not remove them, and
        // `filesToCopy` copies them into every worktree anyway.
        #expect(FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".env")))
    }

    @Test("a repository inside the folder is left out rather than committed as a broken gitlink")
    func keepsNestedRepositoriesOut() async throws {
        guard await hasIdentity() else { return }
        let root = try folder(["README.md": "hello"])
        let nested = (root as NSString).appendingPathComponent("vendor/pkg")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q"], cwd: nested)

        try await RepositoryStarter.start(at: root, destination: .local)
        let committed = try await committedPaths(in: root)
        #expect(committed.contains { $0.hasPrefix("vendor/") } == false)
        #expect(committed.contains(".gitignore"))
    }

    @Test("an existing gitignore is respected and appended to, never rewritten")
    func respectsExistingGitignore() async throws {
        guard await hasIdentity() else { return }
        let root = try folder([
            "README.md": "hello",
            ".gitignore": "# mine\n/.env\nbuild/\n",
            ".env": "SECRET=1",
            "secrets.json": "{}",
        ])

        try await RepositoryStarter.start(at: root, destination: .local)
        let gitignore = try String(
            contentsOfFile: (root as NSString).appendingPathComponent(".gitignore"), encoding: .utf8
        )
        #expect(gitignore.hasPrefix("# mine\n/.env\nbuild/\n"))
        // `.env` was already covered, so no second line was written for it.
        #expect(gitignore.components(separatedBy: "/.env").count == 2)
        #expect(gitignore.contains("/secrets.json"))

        let committed = try await committedPaths(in: root)
        #expect(committed.contains("secrets.json") == false)
        #expect(committed.contains(".env") == false)
    }

    @Test("the commit message is the convention, not a description of somebody's code")
    func commitMessage() async throws {
        guard await hasIdentity() else { return }
        let root = try folder(["README.md": "hello"])
        try await RepositoryStarter.start(at: root, destination: .local)

        let subject = try await Git.check(["log", "-1", "--format=%s"], in: root).trimmed
        #expect(subject == "Initial commit")
        #expect(RepositoryStarter.commitMessage == "Initial commit")
    }

    @Test("the branch is the one git would have made on its own")
    func branchName() async throws {
        guard await hasIdentity() else { return }
        let root = try folder(["README.md": "hello"])
        let outcome = try await RepositoryStarter.start(at: root, destination: .local)
        #expect(outcome.branch == "main")
        #expect(try await Git.currentBranch(of: root) == "main")
    }

    @Test("running it twice changes nothing the second time")
    func idempotent() async throws {
        guard await hasIdentity() else { return }
        let root = try folder(["README.md": "hello"])
        try await RepositoryStarter.start(at: root, destination: .local)
        let head = try await Git.headSHA(of: root)

        try await RepositoryStarter.start(at: root, destination: .local)
        #expect(try await Git.headSHA(of: root) == head)
    }

    @Test("the steps are reported in order, and only the local ones for a local repository")
    func progress() async throws {
        guard await hasIdentity() else { return }
        let root = try folder(["README.md": "hello"])

        let seen = Recorder()
        try await RepositoryStarter.start(at: root, destination: .local) { step in
            seen.append(step)
        }
        #expect(seen.steps == [.initialise, .commit])
        #expect(RepositoryStartStep.steps(for: .local) == [.initialise, .commit])
        #expect(RepositoryStartStep.steps(for: .gitHub(owner: "a", name: "b", isPrivate: true))
            == [.initialise, .commit, .createRemoteRepository, .addOrigin, .push])
    }
}

/// Collects the progress callbacks, which arrive on the main actor and are read off it.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RepositoryStartStep] = []

    var steps: [RepositoryStartStep] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }

    func append(_ step: RepositoryStartStep) {
        lock.lock(); defer { lock.unlock() }
        collected.append(step)
    }
}

@Suite("A sequence that stopped part way")
struct RepositoryStartFailureTests {
    private func failure(
        _ step: RepositoryStartStep,
        completed: Set<RepositoryStartStep>
    ) -> RepositoryStartFailure {
        RepositoryStartFailure(
            step: step,
            message: "it did not work",
            completed: completed,
            destination: .gitHub(owner: "freekmurze", name: "thing", isPrivate: true)
        )
    }

    @Test("a folder nothing reached is described as untouched")
    func nothingHappened() {
        let stopped = failure(.initialise, completed: [])
        #expect(stopped.state.contains("Nothing was changed"))
        #expect(stopped.isUsableProject == false)
    }

    /// The state most worth naming. `git init` with no commit produces a repository that looks
    /// finished and cannot make a single worktree.
    @Test("a repository with no commits says it cannot make a workspace yet")
    func initialisedButNotCommitted() {
        let stopped = failure(.commit, completed: [.initialise])
        #expect(stopped.state.contains("no commits"))
        #expect(stopped.state.contains("worktree"))
        #expect(stopped.isUsableProject == false)
    }

    /// A GitHub failure after a good commit still leaves a project Bloom can run, which is what
    /// makes "add it locally anyway" an honest offer rather than a way to add a broken one.
    @Test("a GitHub failure leaves a usable local project, and says nothing was sent")
    func remoteFailed() {
        let stopped = failure(.createRemoteRepository, completed: [.initialise, .commit])
        #expect(stopped.isUsableProject)
        #expect(stopped.state.contains("Nothing was sent to GitHub"))
        #expect(stopped.state.contains("no repository was created"))
    }

    @Test("a failure after the repository exists names it and says it is still empty")
    func originFailed() {
        let stopped = failure(.addOrigin, completed: [.initialise, .commit, .createRemoteRepository])
        #expect(stopped.state.contains("freekmurze/thing"))
        #expect(stopped.state.contains("empty"))
        #expect(stopped.state.contains("no origin"))
        #expect(stopped.isUsableProject)
    }

    @Test("a failed push says the repository is there and nothing was uploaded")
    func pushFailed() {
        let stopped = failure(
            .push, completed: [.initialise, .commit, .createRemoteRepository, .addOrigin]
        )
        #expect(stopped.state.contains("freekmurze/thing"))
        #expect(stopped.state.contains("Nothing has been uploaded"))
        #expect(stopped.isUsableProject)
    }

    @Test("every step has a heading of its own")
    func titles() {
        let titles = RepositoryStartStep.allCases.map { failure($0, completed: []).title }
        #expect(Set(titles).count == RepositoryStartStep.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test("git's answer is reduced to one line, without its advice")
    func sentences() {
        let shell = ShellError(
            command: "gh repo create",
            status: 1,
            stderr: "GraphQL: Name already exists on this account\nhint: try another name\n"
        )
        #expect(RepositoryStarter.sentence(from: shell) == "GraphQL: Name already exists on this account")

        let long = ShellError(command: "git", status: 1, stderr: String(repeating: "x", count: 500))
        #expect(RepositoryStarter.sentence(from: long).count == 303)
    }

    @Test("git's several ways of saying a key did not work are all recognised", arguments: [
        "error: gpg failed to sign the data",
        "fatal: failed to write commit object",
        "error: failed to fill whole buffer",
        "gpg: signing failed: No secret key",
    ])
    func signingFailures(output: String) {
        #expect(Git.indicatesSigningFailure(output))
    }

    @Test("an ordinary git failure is not mistaken for a signing one")
    func notASigningFailure() {
        #expect(Git.indicatesSigningFailure("nothing to commit, working tree clean") == false)
    }
}

/// Stopping a setup part way through.
///
/// The dialog used to have no way out at all while a step was running: its only button was a
/// disabled Cancel. A `git commit` that never returned, because a signing helper was waiting on an
/// approval nobody was shown, left a modal sheet that could only be escaped by killing the app.
/// What is pinned here is the other half of the fix: stopping has to leave the folder in a state
/// somebody can be told about, and it must not leave a repository behind that Bloom made and
/// nobody asked for.
@Suite("Stopping a repository setup", .tags(.git), .scratchDirectory)
struct RepositoryStartAbandonmentTests {
    private func folder(_ files: [String: String] = [:]) throws -> String {
        let root = TestScratch.unique("bloom-stop")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for (relative, contents) in files {
            let full = (root as NSString).appendingPathComponent(relative)
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func hasIdentity() async -> Bool {
        await RepositoryStarter.identityProblem(at: NSTemporaryDirectory()) == nil
    }

    // MARK: - The decision

    @Test("a folder that never became a repository has nothing to undo")
    func nothingToUndo() {
        #expect(
            RepositoryStartAbandonment.decide(hasGitDirectory: false, hasCommits: false)
                == .nothingToUndo
        )
        // Nonsense on its face, and it still must not reach for a .git that is not there.
        #expect(
            RepositoryStartAbandonment.decide(hasGitDirectory: false, hasCommits: true)
                == .nothingToUndo
        )
    }

    @Test("an initialised repository with no commit is Bloom's to remove")
    func removesTheHalfMadeRepository() {
        #expect(
            RepositoryStartAbandonment.decide(hasGitDirectory: true, hasCommits: false)
                == .repositoryRemoved
        )
    }

    @Test("a repository with a commit in it is left alone, because the commit holds the files")
    func keepsACommittedRepository() {
        let left = RepositoryStartAbandonment.decide(hasGitDirectory: true, hasCommits: true)
        #expect(left == .projectKept)
        #expect(left.isUsableProject)
    }

    @Test("only the kept project counts as one Bloom can run", arguments: [
        RepositoryStartAbandonment.nothingToUndo,
        RepositoryStartAbandonment.repositoryRemoved,
    ])
    func theOthersAreNotProjects(left: RepositoryStartAbandonment) {
        #expect(left.isUsableProject == false)
    }

    @Test("each outcome says what the folder is now, in its own words")
    func states() {
        let states = [
            RepositoryStartAbandonment.nothingToUndo,
            .repositoryRemoved,
            .projectKept,
        ].map(\.state)
        #expect(Set(states).count == 3)
        #expect(states.allSatisfy { !$0.isEmpty })
    }

    // MARK: - On disk

    @Test("stopping after git init takes the repository away again")
    func abandonRemovesTheRepository() async throws {
        let root = try folder(["README.md": "hi\n"])
        _ = try await Git.initRepository(at: root)
        #expect(FileManager.default.fileExists(atPath: root + "/.git"))

        #expect(await RepositoryStarter.abandon(at: root) == .repositoryRemoved)

        #expect(FileManager.default.fileExists(atPath: root + "/.git") == false)
        // Everything that was the user's is untouched. Only what Bloom made is gone.
        #expect(FileManager.default.fileExists(atPath: root + "/README.md"))
        #expect(await Git.isRepository(root) == false)
    }

    @Test("stopping after the first commit keeps the project")
    func abandonKeepsACommittedProject() async throws {
        try #require(await hasIdentity())
        let root = try folder(["README.md": "hi\n"])
        try await RepositoryStarter.start(at: root, destination: .local)

        #expect(await RepositoryStarter.abandon(at: root) == .projectKept)
        #expect(FileManager.default.fileExists(atPath: root + "/.git"))
        #expect(await Git.hasCommits(in: root))
    }

    @Test("stopping before anything happened touches nothing")
    func abandonLeavesAPlainFolderAlone() async throws {
        let root = try folder(["README.md": "hi\n"])
        #expect(await RepositoryStarter.abandon(at: root) == .nothingToUndo)
        #expect(FileManager.default.fileExists(atPath: root + "/README.md"))
        #expect(await Git.isRepository(root) == false)
    }

    // MARK: - Patience

    @Test("every step is given a limit and has something to say once it runs out")
    func patience() {
        for step in RepositoryStartStep.allCases {
            #expect(step.patience > .zero)
            #expect(!step.slowNotice.isEmpty)
            // It names the thing to go and look at, which is the only reason to print it.
            #expect(step.slowNotice.count > 40)
        }
        // The push is the one step that is legitimately long, so it is the most patient of them.
        #expect(RepositoryStartStep.push.patience > RepositoryStartStep.commit.patience)
        #expect(Set(RepositoryStartStep.allCases.map(\.slowNotice)).count
            == RepositoryStartStep.allCases.count)
    }
}
