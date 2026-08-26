import Testing
import Foundation
@testable import BloomCore

/// Real git and real directories, in the running test's scratch folder. Nothing here goes near
/// GitHub: a new project is local by design.
@Suite("Starting a project from nothing", .tags(.git), .scratchDirectory)
struct NewProjectStarterTests {
    /// git will not commit without a name and an address, and this machine's git is the one making
    /// the commit. Every test that commits says so rather than failing obscurely.
    private func hasIdentity() async -> Bool {
        await RepositoryStarter.identityProblem(at: NSTemporaryDirectory()) == nil
    }

    private func scratch() -> (location: String, name: String) {
        (TestScratch.unique("bloom-new"), "sparkline")
    }

    private func inspect(_ location: String, _ name: String) -> NewProjectFacts {
        NewProjectStarter.inspect(
            name: name,
            location: location,
            home: NSHomeDirectory(),
            workspacesRoot: TestScratch.path("workspaces")
        )
    }

    // MARK: - Looking

    @Test("a path with nothing at it, under a location that is not there either, is created")
    func createsBoth() {
        let (location, name) = scratch()
        let facts = inspect(location, name)
        #expect(facts.locationExists == false)
        #expect(facts.targetExists == false)
        #expect(NewProjectVerdict.of(facts) == .create(makesLocation: true))
    }

    @Test("an empty folder that is already there is adopted, and one with a file in it is not")
    func adoptsOnlyWhatIsEmpty() throws {
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        #expect(NewProjectVerdict.of(inspect(location, name)) == .adopt)

        // The Finder writes one of these into any folder somebody has opened, and it is not
        // content: refusing it would refuse the empty folder a person just made in the file panel.
        try "".write(
            toFile: (target as NSString).appendingPathComponent(".DS_Store"),
            atomically: true, encoding: .utf8
        )
        #expect(NewProjectVerdict.of(inspect(location, name)) == .adopt)

        try "hello".write(
            toFile: (target as NSString).appendingPathComponent("notes.md"),
            atomically: true, encoding: .utf8
        )
        guard case .refuse(.folderNotEmpty) = NewProjectVerdict.of(inspect(location, name)) else {
            Issue.record("a folder with a file in it was not refused")
            return
        }
    }

    @Test("a location inside an existing repository is refused rather than nested")
    func refusesNesting() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let facts = inspect((repo.path as NSString).appendingPathComponent("sub"), "sparkline")
        guard case .refuse(.insideRepository) = NewProjectVerdict.of(facts) else {
            Issue.record("a folder inside \(repo.path) was not refused")
            return
        }
    }

    // MARK: - Doing

    /// The whole point of the flow, end to end. The empty commit is what makes the project usable
    /// the moment it appears in the sidebar: without it `workspace_start` refuses with
    /// `projectHasNoCommits` and the first thing anybody does with their new project fails.
    @Test("a project made from nothing can have a workspace cut from it straight away")
    func createsAProjectAWorktreeCanStartFrom() async throws {
        guard await hasIdentity() else { return }
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)

        let seen = StepRecorder()
        let creation = try await NewProjectStarter.create(at: target) { step in
            seen.append(step)
        }

        #expect(creation.folderWasCreated)
        #expect(creation.branch == "main")
        #expect(seen.steps == [.initialise, .commit])
        #expect(await Git.isRepository(target))
        #expect(await Git.hasCommits(in: target))
        // Nothing of Bloom's own: no README, no .gitignore. The first thing in the history is
        // whatever the person or their agent puts there.
        #expect(try await Git.check(["ls-tree", "-r", "--name-only", "HEAD"], in: target).lines.isEmpty)

        // The refusal this is all in aid of, asked exactly as `WorkspaceTrouble.creating` asks it.
        #expect(await CheckoutStanding.of(target, branch: creation.branch) == .fine)

        let worktree = TestScratch.unique("worktree")
        try await Git.addWorktree(
            repo: target, path: worktree, branch: "bloom/test", base: creation.branch
        )
        #expect(FileManager.default.fileExists(atPath: worktree))
        try await Git.removeWorktree(repo: target, path: worktree, force: true)
    }

    @Test("an empty folder that was already there is used rather than made")
    func adoptsRatherThanMakes() async throws {
        guard await hasIdentity() else { return }
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)

        let creation = try await NewProjectStarter.create(at: target)
        #expect(creation.folderWasCreated == false)
        #expect(await Git.hasCommits(in: target))
    }

    // MARK: - Undoing

    @Test("abandoning takes away exactly what Bloom made")
    func discardRemovesTheFolderBloomMade() async throws {
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q"], cwd: target)

        let left = await NewProjectStarter.discard(at: target, folderWasCreated: true)
        #expect(left.repository == .repositoryRemoved)
        #expect(left.folderRemoved)
        #expect(FileManager.default.fileExists(atPath: target) == false)
        #expect(left.state.contains("nothing is left on disk"))
    }

    /// A folder Bloom did not make is not Bloom's to remove, however empty it is.
    @Test("an adopted folder keeps its place, with the git init undone")
    func discardKeepsAnAdoptedFolder() async throws {
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q"], cwd: target)

        let left = await NewProjectStarter.discard(at: target, folderWasCreated: false)
        #expect(left.repository == .repositoryRemoved)
        #expect(left.folderRemoved == false)
        #expect(FileManager.default.fileExists(atPath: target))
        #expect(FileManager.default.fileExists(atPath: (target as NSString).appendingPathComponent(".git")) == false)
    }

    /// The moment there is a commit the folder holds work, and work is never Bloom's to delete.
    @Test("a project that reached its first commit is left exactly as it is")
    func discardKeepsAProject() async throws {
        guard await hasIdentity() else { return }
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)
        _ = try await NewProjectStarter.create(at: target)

        let left = await NewProjectStarter.discard(at: target, folderWasCreated: true)
        #expect(left.repository == .projectKept)
        #expect(left.folderRemoved == false)
        #expect(left.isUsableProject)
        #expect(FileManager.default.fileExists(atPath: target))
    }

    /// Somebody dropped a file into the new folder while the dialog was up. It is theirs.
    @Test("a folder that has gained something in the meantime is not removed")
    func discardKeepsAFolderThatIsNoLongerEmpty() async throws {
        let (location, name) = scratch()
        let target = (location as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "mine".write(
            toFile: (target as NSString).appendingPathComponent("notes.md"),
            atomically: true, encoding: .utf8
        )

        let left = await NewProjectStarter.discard(at: target, folderWasCreated: true)
        #expect(left.folderRemoved == false)
        #expect(FileManager.default.fileExists(atPath: target))
    }
}

/// Collects the progress callbacks, which arrive on the main actor and are read off it.
private final class StepRecorder: @unchecked Sendable {
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
