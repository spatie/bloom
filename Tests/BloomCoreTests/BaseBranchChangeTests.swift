import Foundation
import Testing
@testable import BloomCore

@Suite("Changing a workspace's base branch")
struct BaseBranchChangeTests {
    @Test("Local and remote branches are offered once, in order, without the workspace's own")
    func options() {
        #expect(
            BaseBranchChange.options(
                local: ["main", "quiet-harbour", "ownweb"],
                remote: ["main", "colleague/idea", ""],
                excluding: "quiet-harbour"
            ) == ["colleague/idea", "main", "ownweb"]
        )
    }

    @Test("The workspace's own branch is refused, even when the listing has it")
    func ownBranchRefused() {
        let refusal = BaseBranchChange.refusal(
            of: "quiet-harbour", branch: "quiet-harbour", available: ["main", "quiet-harbour"]
        )
        #expect(refusal?.contains("own branch") == true)
    }

    @Test("A branch the listing does not have is refused")
    func missingBranchRefused() {
        let refusal = BaseBranchChange.refusal(
            of: "deleted-meanwhile", branch: "quiet-harbour", available: ["main", "ownweb"]
        )
        #expect(refusal?.contains("not a branch") == true)
    }

    @Test("A workspace with no worktree on this Mac lists nothing rather than asking elsewhere")
    func noWorktreeListsNothing() async {
        #expect(await BaseBranchChange.load(repoPath: "", excluding: "quiet-harbour").isEmpty)
    }

    @Test("A listed branch is accepted")
    func listedBranchAccepted() {
        #expect(
            BaseBranchChange.refusal(of: "ownweb", branch: "quiet-harbour", available: ["main", "ownweb"])
                == nil
        )
    }
}

@Suite("Following an open pull request's target")
struct BaseBranchAdoptionTests {
    private let workspace = Workspace(
        repoID: RepoID("repo"), name: "Caribbean Sea", branch: "caribbean-sea", path: "/p", baseBranch: "main"
    )

    private func request(state: String = "OPEN", base: String?) -> PullRequest {
        PullRequest(number: 12, title: "Sea", url: "", state: state, branch: "caribbean-sea", baseBranch: base)
    }

    @Test("An open pull request aimed elsewhere moves the base")
    func openRetargeted() {
        #expect(BaseBranchChange.adopted(from: request(base: "ownweb"), by: workspace) == "ownweb")
    }

    @Test("Nothing moves when the target already is the base, or is not known")
    func nothingToFollow() {
        #expect(BaseBranchChange.adopted(from: request(base: "main"), by: workspace) == nil)
        #expect(BaseBranchChange.adopted(from: request(base: nil), by: workspace) == nil)
        #expect(BaseBranchChange.adopted(from: nil, by: workspace) == nil)
    }

    @Test("A merged or closed pull request is history and moves nothing")
    func finishedIsHistory() {
        #expect(BaseBranchChange.adopted(from: request(state: "MERGED", base: "ownweb"), by: workspace) == nil)
        #expect(BaseBranchChange.adopted(from: request(state: "CLOSED", base: "ownweb"), by: workspace) == nil)
    }

    @Test("Neither the workspace's own branch nor a name git would refuse becomes the base")
    func refusedTargets() {
        #expect(BaseBranchChange.adopted(from: request(base: "caribbean-sea"), by: workspace) == nil)
        #expect(BaseBranchChange.adopted(from: request(base: "-rf"), by: workspace) == nil)
    }
}

@Suite("Listing a workspace's possible bases", .tags(.git, .destructive), .scratchDirectory)
struct BaseBranchChangeListingTests {
    @Test("A worktree lists the repository's branches, less its own")
    func listsFromWorktree() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("base-branch-change")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        try await Shell.check("git", ["branch", "ownweb"], cwd: repo.path)

        let options = await BaseBranchChange.load(repoPath: workspace.path, excluding: workspace.branch)

        #expect(options.contains("main"))
        #expect(options.contains("ownweb"))
        #expect(!options.contains(workspace.branch))
    }

    @Test("A new base is written where git and gh read it, not only in the store")
    func recordsInGit() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("base-branch-record")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        try await Shell.check("git", ["branch", "ownweb"], cwd: repo.path)

        try await BaseBranchChange.record("ownweb", for: workspace)

        let recorded = try await Shell.run(
            "git", ["config", "branch.\(workspace.branch).gh-merge-base"], cwd: workspace.path
        )
        #expect(recorded.trimmed == "ownweb")
        #expect(try await Git.repositoryContext(in: workspace.path).baseBranch == "ownweb")
    }

    @Test("A target this clone can resolve is followed, one it cannot is left alone")
    func adoptsOnlyResolvableTargets() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("base-branch-adoption")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        try await Shell.check("git", ["branch", "ownweb"], cwd: repo.path)

        func open(_ base: String) -> PullRequest {
            PullRequest(number: 1, title: "", url: "", state: "OPEN", branch: workspace.branch, baseBranch: base)
        }
        #expect(await BaseBranchChange.adoptable(from: open("ownweb"), by: workspace) == "ownweb")
        #expect(await BaseBranchChange.adoptable(from: open("nowhere"), by: workspace) == nil)
    }

    @Test("A target that resolves to another remote than the current base is left alone")
    func keepsToTheSameRemote() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("base-branch-adoption-remote")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        try await Shell.check("git", ["branch", "ownweb"], cwd: repo.path)
        try await Shell.check("git", ["remote", "add", "origin", "/nowhere/fork"], cwd: repo.path)
        try await Shell.check("git", ["remote", "add", "upstream", "/nowhere/upstream"], cwd: repo.path)
        try await Shell.check("git", ["config", "branch.ownweb.remote", "upstream"], cwd: repo.path)

        let retargeted = PullRequest(
            number: 1, title: "", url: "", state: "OPEN", branch: workspace.branch, baseBranch: "ownweb"
        )
        #expect(await BaseBranchChange.adoptable(from: retargeted, by: workspace) == nil)
    }
}
