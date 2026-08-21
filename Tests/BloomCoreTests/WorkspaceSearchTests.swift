import Foundation
import Testing
@testable import BloomCore

/// Finding a workspace by typing at it.
///
/// One rule, checked here directly, because three screens ask this question and two of them used
/// to answer it differently: the Shortcuts entity query matched the name and the branch but not
/// the project, so a workspace the search field found was one Siri could not.
@Suite("Workspace search")
struct WorkspaceSearchTests {
    private func workspace(
        name: String = "add-caching",
        branch: String = "feature/add-caching",
        repoID: RepoID = RepoID("repo")
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(name),
            repoID: repoID,
            name: name,
            branch: branch,
            path: "/tmp/\(name)",
            baseBranch: "main",
            state: .active,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
    }

    private let repo = Repo(id: RepoID("repo"), name: "there-there", path: "/tmp/there-there")

    @Test("the needle is what the user typed, trimmed and lowercased")
    func needle() {
        #expect(WorkspaceSearch.needle("  Add-Caching  ") == "add-caching")
        #expect(WorkspaceSearch.needle("  ADD  ") == "add")
        #expect(WorkspaceSearch.needle("   ") == "")
    }

    @Test("a name match answers with the name")
    func matchesName() {
        #expect(WorkspaceSearch.match(workspace: workspace(), repo: repo, needle: "cach") == "add-caching")
    }

    @Test("a branch match answers with the branch")
    func matchesBranch() {
        let found = WorkspaceSearch.match(workspace: workspace(), repo: repo, needle: "feature/")
        #expect(found == "feature/add-caching")
    }

    @Test("a project match answers with the project, which the Shortcuts query used to miss")
    func matchesRepo() {
        #expect(WorkspaceSearch.match(workspace: workspace(), repo: repo, needle: "there") == "there-there")
    }

    @Test("the name is answered with first when more than one field matches")
    func nameWinsOverBranch() {
        let both = workspace(name: "caching", branch: "feature/caching")
        #expect(WorkspaceSearch.match(workspace: both, repo: repo, needle: "caching") == "caching")
    }

    @Test("matching ignores case on both sides")
    func caseInsensitive() {
        let shouty = workspace(name: "ADD-CACHING")
        #expect(WorkspaceSearch.match(workspace: shouty, repo: repo, needle: "cach") == "ADD-CACHING")
    }

    @Test("a workspace with no project still matches on its own two fields")
    func repolessWorkspace() {
        #expect(WorkspaceSearch.match(workspace: workspace(), repo: nil, needle: "cach") != nil)
        #expect(WorkspaceSearch.match(workspace: workspace(), repo: nil, needle: "there") == nil)
    }

    @Test("nothing matches an empty needle, so a caller has to say what it means by it")
    func emptyNeedleMatchesNothing() {
        #expect(WorkspaceSearch.match(workspace: workspace(), repo: repo, needle: "") == nil)
    }

    @Test("an unfiltered list reads an empty needle as show everything")
    func emptyNeedleIsUnfiltered() {
        #expect(WorkspaceSearch.matchesOrIsUnfiltered(workspace: workspace(), repo: repo, needle: ""))
        #expect(!WorkspaceSearch.matchesOrIsUnfiltered(workspace: workspace(), repo: repo, needle: "zzz"))
    }

    @Test("Home's filter and the search field agree about the project name")
    func homeFilterFindsByProject() {
        let listing = HomeList.build(
            repos: [repo],
            workspaces: [workspace()],
            archived: [],
            filter: HomeFilter(query: "there-there"),
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(listing.shown == 1)
    }
}
