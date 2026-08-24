import Testing
import Foundation
@testable import BloomCore

/// The three answers to "how many workspaces may this caller start", which used to be in three
/// places and one of them was silence.
@Suite("Workspace start allowance")
struct WorkspaceStartAllowanceTests {
    @Test("who asked decides which brake applies")
    func brakePerOrigin() {
        #expect(WorkspaceStartAllowance.of(.user) == .unlimited)
        #expect(
            WorkspaceStartAllowance
                .of(.agent(parentWorkspaceID: WorkspaceID("w1"), spawnToolUseID: "t1"))
                == .running(limit: WorkspaceStartAllowance.maximumChildren)
        )
        #expect(
            WorkspaceStartAllowance.of(.ownerClient(spawnToolUseID: "t1"))
                == .rate(
                    limit: WorkspaceStartAllowance.maximumOwnerStarts,
                    window: WorkspaceStartAllowance.ownerWindow
                )
        )
    }

    /// The sheet is not an oversight. One human gesture per workspace is the brake, so nothing
    /// else has to be.
    @Test("the owner's own hand is never refused, however many they have")
    func theSheetIsUncapped() {
        #expect(WorkspaceStartAllowance.unlimited.refusal(count: 400) == nil)
        #expect(!WorkspaceStartAllowance.unlimited.isExceeded(by: 400))
    }

    @Test("a ceiling refuses at the limit and not below it")
    func ceiling() {
        let allowance = WorkspaceStartAllowance.running(limit: 8)

        #expect(allowance.refusal(count: 7) == nil)
        #expect(allowance.refusal(count: 8)?.contains("which is Bloom's limit") == true)
        #expect(allowance.refusal(count: 9)?.contains("9 workspaces running") == true)
    }

    @Test("a rate refuses at the limit and not below it")
    func rate() {
        let allowance = WorkspaceStartAllowance.rate(limit: 6, window: 15 * 60)

        #expect(allowance.refusal(count: 5) == nil)
        #expect(allowance.refusal(count: 6)?.contains("in the last 15 minutes") == true)
    }

    /// A model that has just been refused reads any mention of a window as a timer to wait out,
    /// and a model that waits and retries has turned a brake into a slower loop.
    @Test("the rate refusal says that waiting and retrying are both pointless")
    func theRateRefusalHeadsOffARetryLoop() throws {
        let sentence = try #require(
            WorkspaceStartAllowance.rate(limit: 6, window: 15 * 60).refusal(count: 6)
        )

        #expect(sentence.contains("do not retry and do not wait for it"))
        #expect(sentence.contains("nothing you can do here shortens"))
        // No path and no command, and nothing the owner could be asked to raise from here.
        #expect(!sentence.contains("/"))
    }
}
