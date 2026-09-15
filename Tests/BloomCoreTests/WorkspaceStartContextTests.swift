import Testing
@testable import BloomCore

/// The two branch decisions the create window used to make inside its own `load`, which is why
/// they had no tests until they moved here.
@Suite("Workspace start context")
struct WorkspaceStartContextTests {
    // MARK: - What the picker offers

    @Test("A real listing is offered as it is")
    func optionsPassThrough() {
        #expect(
            WorkspaceStartContext.branchOptions(branches: ["main", "wip"], defaultBranch: "main")
                == ["main", "wip"]
        )
    }

    @Test("An empty listing still offers the default branch")
    func optionsFallBackToDefault() {
        #expect(
            WorkspaceStartContext.branchOptions(branches: [], defaultBranch: "main") == ["main"]
        )
    }

    @Test("A branch only the remote has is offered as a base, once, in order")
    func remoteOnlyBranchesAreBases() {
        #expect(
            WorkspaceStartContext.baseBranchOptions(
                local: ["main", "wip"],
                remote: ["main", "colleague/idea", "wip"],
                defaultBranch: "main"
            ) == ["colleague/idea", "main", "wip"]
        )
    }

    @Test("Only the primary remote's branches are offered, origin first")
    func primaryRemoteOnly() {
        let references = ["origin/HEAD", "origin/main", "origin/idea", "upstream/elsewhere"]
        #expect(
            WorkspaceStartContext.primaryRemoteBranches(
                references: references, remoteNames: ["upstream", "origin"]
            ) == ["main", "idea"]
        )
        #expect(
            WorkspaceStartContext.primaryRemoteBranches(
                references: ["github/main"], remoteNames: ["github"]
            ) == ["main"]
        )
        #expect(
            WorkspaceStartContext.primaryRemoteBranches(references: [], remoteNames: []).isEmpty
        )
    }

    @Test("No branches on either side still offers the default branch")
    func noBasesFallBackToDefault() {
        #expect(
            WorkspaceStartContext.baseBranchOptions(local: [], remote: [], defaultBranch: "main")
                == ["main"]
        )
    }

    // MARK: - Where the worktree is cut from

    @Test("A choice that survives the listing is kept")
    func currentChoiceSurvives() {
        #expect(
            WorkspaceStartContext.resolvedBaseBranch(
                current: "release",
                branches: ["main", "release"],
                defaultBranch: "main"
            ) == "release"
        )
    }

    @Test("A stale choice falls back to the default branch")
    func staleChoiceFallsBackToDefault() {
        #expect(
            WorkspaceStartContext.resolvedBaseBranch(
                current: "gone",
                branches: ["main", "wip"],
                defaultBranch: "main"
            ) == "main"
        )
    }

    @Test("A repository without its default branch offers the first branch there is")
    func missingDefaultFallsBackToFirst() {
        #expect(
            WorkspaceStartContext.resolvedBaseBranch(
                current: "",
                branches: ["trunk", "wip"],
                defaultBranch: "main"
            ) == "trunk"
        )
    }

    @Test("No branches at all still answers with the default branch")
    func emptyListingAnswersDefault() {
        #expect(
            WorkspaceStartContext.resolvedBaseBranch(
                current: "",
                branches: [],
                defaultBranch: "main"
            ) == "main"
        )
    }

    @Test("The empty sheet default never survives a real listing")
    func emptyCurrentIsNeverKept() {
        // The sheet opens with `baseBranch` empty. "" is not a branch, so resolution must move
        // off it the moment the listing lands rather than keeping it as a current choice.
        #expect(
            WorkspaceStartContext.resolvedBaseBranch(
                current: "",
                branches: ["main", "wip"],
                defaultBranch: "main"
            ) == "main"
        )
    }
}
