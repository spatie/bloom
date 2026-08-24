import Testing
@testable import BloomCore

@Suite("Whether a workspace may be started")
struct WorkspaceStartPlanTests {
    @Test("a chat needs words")
    func chatNeedsWords() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: false,
            isChatWorkspace: true, isBusy: false
        ))
        #expect(WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "Fix the login flow", hasCheckout: false,
            isChatWorkspace: true, isBusy: false
        ))
    }

    @Test("whitespace is not words")
    func whitespaceIsNotWords() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "   \n\t ", hasCheckout: false,
            isChatWorkspace: true, isBusy: false
        ))
    }

    /// The whole point of the feature. A worktree, a branch and a shell is a complete request, and
    /// requiring a sentence for it was requiring somebody to describe work they were about to do
    /// by hand to an agent that is never going to read it.
    @Test("a terminal needs nothing written at all")
    func terminalNeedsNothing() {
        #expect(WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: false,
            isChatWorkspace: false, isBusy: false
        ))
    }

    @Test("a checkout needs nothing written, because the pull request brought its own name")
    func checkoutNeedsNothing() {
        #expect(WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: true,
            isChatWorkspace: true, isBusy: false
        ))
    }

    @Test("no project, no start, whatever else is true")
    func projectIsRequired() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: false, prompt: "Fix the login flow", hasCheckout: true,
            isChatWorkspace: false, isBusy: false
        ))
    }

    /// A second press while the first worktree is being cut is how two workspaces race for one
    /// branch name, so the guard covers the route that needs no words as well as the one that does.
    @Test("a create already in flight blocks every route")
    func busyBlocksEveryRoute() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "Fix the login flow", hasCheckout: false,
            isChatWorkspace: true, isBusy: true
        ))
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: false,
            isChatWorkspace: false, isBusy: true
        ))
    }

    @Test("a typed branch names a terminal workspace")
    func typedBranchNames() {
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: "spike/perf", claimedSea: "Coral Sea"
        ) == "spike/perf")
    }

    @Test("otherwise the sea does")
    func seaNames() {
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: nil, claimedSea: "Coral Sea"
        ) == "Coral Sea")
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: "", claimedSea: "Coral Sea"
        ) == "Coral Sea")
    }

    /// An exhausted catalogue, or a store that is not there yet. Nil is handed back rather than
    /// invented, and `Git.title` answers "New workspace" for the empty prompt behind it.
    @Test("with neither, nothing is claimed to be the name")
    func neitherNames() {
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: nil, claimedSea: nil
        ) == nil)
    }
}
