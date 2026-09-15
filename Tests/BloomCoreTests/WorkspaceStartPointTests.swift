import Foundation
import Testing
@testable import BloomCore

/// Where a new workspace's branch starts.
///
/// The report: a new workspace "from main" was cut from the local `main`, which Bloom never moves,
/// so on a clone nobody pulls in every workspace started out of date. It starts from `origin/main`
/// as a fetch has just left it now, and the local branch is still left exactly where it was.
@Suite("Start point of a new workspace", .tags(.git), .scratchDirectory)
struct WorkspaceStartPointTests {
    private func clone(of server: TempRepo, named name: String) async throws -> TempRepo {
        let path = TestScratch.unique(name)
        try await Shell.check("git", ["clone", "-q", server.path, path])
        try await Shell.check("git", ["config", "user.email", "test@bloom.local"], cwd: path)
        try await Shell.check("git", ["config", "user.name", "Bloom Test"], cwd: path)
        try await Shell.check("git", ["config", "commit.gpgsign", "false"], cwd: path)
        return TempRepo(existing: path)
    }

    private func commitAll(_ repo: TempRepo, _ message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", message], cwd: repo.path)
    }

    @Test("a new workspace starts from the base as the remote has it, not the stale local copy")
    func startsFromTheRemote() async throws {
        let server = try await TempRepo()
        defer { server.cleanUp() }
        let work = try await clone(of: server, named: "stale-clone")
        defer { work.cleanUp() }

        let stale = try await Git.headSHA(of: work.path)
        try server.write("landed.md", "merged while the clone sat still\n")
        try await commitAll(server, "land something")
        let current = try await Git.headSHA(of: server.path)

        let manager = WorkspaceManager(store: try makeTestStore("start-from-remote"))
        let registered = try await manager.addRepository(at: work.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Next thing")

        #expect(try await Git.headSHA(of: workspace.path) == current)
        #expect(workspace.baseBranch == registered.defaultBranch)
        #expect(await Git.revision(of: "refs/heads/\(registered.defaultBranch)", in: work.path) == stale)
    }

    @Test("a branch only the remote has is a base a workspace can start from")
    func startsFromARemoteOnlyBranch() async throws {
        let server = try await TempRepo()
        defer { server.cleanUp() }
        let work = try await clone(of: server, named: "remote-only-base")
        defer { work.cleanUp() }

        try await Shell.check("git", ["checkout", "-q", "-b", "colleague/idea"], cwd: server.path)
        try server.write("idea.md", "pushed after the clone was made\n")
        try await commitAll(server, "an idea")
        let idea = try await Git.headSHA(of: server.path)

        let manager = WorkspaceManager(store: try makeTestStore("start-from-remote-only"))
        let registered = try await manager.addRepository(at: work.path)
        let workspace = try await manager.createWorkspace(
            repo: registered, prompt: "Build on the idea", baseBranch: "colleague/idea"
        )

        #expect(try await Git.headSHA(of: workspace.path) == idea)
        #expect(workspace.baseBranch == "colleague/idea")
    }

    @Test("a repository with no remote still starts from its local branch")
    func noRemoteUsesTheLocalBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)

        let manager = WorkspaceManager(store: try makeTestStore("start-without-remote"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Local only")

        #expect(try await Git.headSHA(of: workspace.path) == head)
    }
}
