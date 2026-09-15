import Foundation
import Testing
@testable import BloomCore

@Suite("RemoteCreationWait")
struct RemoteCreationWaitTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func phase(after seconds: TimeInterval, connected: Bool = true, heard: TimeInterval? = nil) -> RemoteCreationWait.Phase {
        RemoteCreationWait.phase(startedAt: start, now: start + seconds, isConnected: connected,
                                 lastHeardAt: heard.map { start + $0 })
    }

    /// A create that answers promptly must never flash a second screen, even over a connection
    /// that has just dropped: the request fails on its own a moment later and says why.
    @Test func theFirstSecondsAreQuiet() {
        #expect(phase(after: 0) == .quiet)
        #expect(phase(after: 1.9, connected: false) == .quiet)
    }

    @Test func aServerThatKeepsAnsweringIsWorkingHoweverLongItTakes() {
        #expect(phase(after: 2, heard: 1) == .waiting)
        #expect(phase(after: 900, heard: 895) == .waiting)
    }

    @Test func aDroppedConnectionIsNotResponding() {
        #expect(phase(after: 3, connected: false, heard: 2.5) == .notResponding)
    }

    @Test func silenceIsCountedFromTheLastReply() {
        #expect(phase(after: 60, heard: 40) == .waiting)
        #expect(phase(after: 61, heard: 40) == .notResponding)
    }

    /// A connection idle before Create was pressed has not been silent during the create.
    @Test func silenceNeverStartsBeforeCreate() {
        #expect(phase(after: 15, heard: -300) == .waiting)
        #expect(phase(after: 21, heard: -300) == .notResponding)
        #expect(phase(after: 21) == .notResponding)
        #expect(RemoteCreationWait.silence(startedAt: start, now: start + 5, lastHeardAt: start - 300) == 5)
    }

    @Test func theActivityNamesWhatWasAskedFor() {
        let pull = PullRequestListing(number: 435, title: "Docker workspaces", headRefName: "bloom/docker-workspaces", baseRefName: "main")
        #expect(RemoteCreationWait.activity(checkout: .pullRequest(pull), baseBranch: "main")
            == "Fetching pull request #435 (bloom/docker-workspaces) and checking it out in a new worktree.")
        #expect(RemoteCreationWait.activity(checkout: .branch(ExistingBranch(name: "develop", isLocal: false)), baseBranch: "main")
            == "Fetching develop and checking it out in a new worktree.")
        #expect(RemoteCreationWait.activity(checkout: nil, baseBranch: "main") == "Creating a new branch from main and its worktree.")
        #expect(RemoteCreationWait.activity(checkout: nil, baseBranch: "") == "Creating a new branch and its worktree.")
    }

    @Test func theClockKeepsItsShape() {
        #expect(RemoteCreationWait.clock(7) == "0:07")
        #expect(RemoteCreationWait.clock(760) == "12:40")
        #expect(RemoteCreationWait.clock(3_725) == "1:02:05")
        #expect(RemoteCreationWait.clock(-4) == "0:00")
    }
}
