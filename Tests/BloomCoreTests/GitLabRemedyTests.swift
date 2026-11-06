import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab remedies")
struct GitLabRemedyTests {
    @Test("a merge request that needs a rebase offers one, and no other blocker does")
    func rebase() {
        let needsRebase = PullRequest(
            number: 3, title: "", url: "", state: "OPEN", forge: .gitLab, blockers: [.needsRebase]
        )
        #expect(needsRebase.status.remedy == .rebase)
        #expect(needsRebase.status.canMerge == false)

        let unapproved = PullRequest(
            number: 3, title: "", url: "", state: "OPEN", forge: .gitLab, blockers: [.approvalRequired]
        )
        #expect(unapproved.status.remedy == .merge)
        #expect(unapproved.status.canMerge == false)
    }
}
