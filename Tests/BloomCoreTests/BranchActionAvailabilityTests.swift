import Foundation
import Testing
@testable import BloomCore

@Suite("Whether the branch may be acted on")
struct BranchActionAvailabilityTests {
    @Test("Creating a pull request can submit a message while idle or busy", arguments: [false, true])
    func creationAllows(isAgentBusy: Bool) {
        let availability = BranchActionAvailability.mayActOnBranch(
            isAgentBusy: isAgentBusy, pullRequest: nil
        )
        #expect(availability == .allowed)
    }

    @Test("Open pull request actions can submit messages while idle or busy", arguments: [false, true])
    func openAllows(isAgentBusy: Bool) {
        let availability = BranchActionAvailability.mayActOnBranch(
            isAgentBusy: isAgentBusy, pullRequest: pullRequest(state: "OPEN")
        )
        #expect(availability == .allowed)
        #expect(availability.note == nil)
        #expect(availability.reason == nil)
    }

    @Test("Immediate workspace actions still wait for the agent", arguments: ["MERGED", "CLOSED"])
    func finishedBlocksWhileBusy(state: String) {
        let availability = BranchActionAvailability.mayActOnBranch(
            isAgentBusy: true, pullRequest: pullRequest(state: state)
        )
        #expect(!availability.isAllowed)
        #expect(availability.note?.isEmpty == false)
        #expect((availability.note?.count ?? 0) <= 40)
        #expect(availability.reason?.contains("Continue and Archive") == true)
    }

    @Test("Immediate workspace actions become available when idle", arguments: ["MERGED", "CLOSED"])
    func finishedAllowsWhenIdle(state: String) {
        let availability = BranchActionAvailability.mayActOnBranch(
            isAgentBusy: false, pullRequest: pullRequest(state: state)
        )
        #expect(availability == .allowed)
    }

    private func pullRequest(state: String) -> PullRequest {
        PullRequest(number: 42, title: "Ship it", url: "https://github.com/acme/app/pull/42", state: state)
    }
}
