import Testing
@testable import BloomCore

/// The pull request band spins only before it has ever had an answer. Every other refresh leaves
/// what is on screen alone, which is what stops Create pull request being replaced by a spinner
/// and put back on every poll and every view change.
@Suite("When the pull request band says it is working")
struct PullRequestProgressTests {
    @Test("the first look at a workspace spins")
    func firstLook() {
        #expect(PullRequestProgress.announces(hasAnswered: false, hasPullRequest: false))
    }

    @Test("a refresh of a branch already known to have none is silent")
    func refreshOfNoPullRequest() {
        #expect(!PullRequestProgress.announces(hasAnswered: true, hasPullRequest: false))
    }

    @Test("a refresh of one already on screen is silent")
    func refreshOfExisting() {
        #expect(!PullRequestProgress.announces(hasAnswered: true, hasPullRequest: true))
        #expect(!PullRequestProgress.announces(hasAnswered: false, hasPullRequest: true))
    }
}
