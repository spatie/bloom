import Foundation
import Testing
@testable import BloomCore

/// Whether the pull request strip may act on the branch.
///
/// The report: the green Merge button, and the red Fix merge conflicts button beside the same
/// headline, were both live while the workspace's agent was mid turn. Merging there lands a
/// branch whose commits may not all be pushed yet and deletes it on the server, which is the one
/// thing this app offers that cannot be undone from inside it.
@Suite("Whether the branch may be acted on")
struct BranchActionAvailabilityTests {
    @Test("An idle workspace may act, and says nothing about it")
    func idleAllows() {
        let availability = BranchActionAvailability.mayActOnBranch(isAgentBusy: false)
        #expect(availability.isAllowed)
        #expect(availability.note == nil)
        #expect(availability.reason == nil)
    }

    @Test("A running agent holds every branch action back")
    func busyBlocks() {
        #expect(!BranchActionAvailability.mayActOnBranch(isAgentBusy: true).isAllowed)
    }

    /// Both of them, because they are two different readers. The note is read off the strip by
    /// somebody who never hovers anything; the reason is what the disabled control answers with
    /// when they do.
    @Test("It says why, on the strip and in the tooltip")
    func busyExplainsItself() {
        let availability = BranchActionAvailability.mayActOnBranch(isAgentBusy: true)
        #expect(availability.note?.isEmpty == false)
        #expect(availability.reason?.isEmpty == false)
        #expect(availability.reason?.contains("worktree") == true)
    }

    /// The note shares one line of a strip that is exactly one row tall, beside a headline that
    /// must not be the thing that truncates. A sentence is not what goes there.
    @Test("The note is short enough for the line it takes over")
    func noteIsShort() {
        let note = BranchActionAvailability.mayActOnBranch(isAgentBusy: true).note ?? ""
        #expect(note.count <= 40)
    }

    @Test("Allowed is the same answer as an idle workspace")
    func allowedMatchesIdle() {
        #expect(BranchActionAvailability.mayActOnBranch(isAgentBusy: false) == .allowed)
    }
}
