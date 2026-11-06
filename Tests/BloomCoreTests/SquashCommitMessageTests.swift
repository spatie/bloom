import Foundation
import Testing
@testable import BloomCore

@Suite("Squash commit message")
struct SquashCommitMessageTests {
    private let pullRequest = PullRequest(number: 12, title: "Ship it", url: "", state: "OPEN")

    @Test("the proposal is GitHub's own subject, and leaving it adds nothing to the turn")
    func untouched() {
        let proposed = SquashCommitMessage.proposed(for: pullRequest)
        #expect(proposed == SquashCommitMessage(subject: "Ship it (#12)"))
        #expect(proposed.instruction(proposed: proposed) == nil)
        #expect(SquashCommitMessage(subject: "  ").instruction(proposed: proposed) == nil)
    }

    @Test("an edited subject alone is passed as --subject, leaving GitHub's body")
    func subjectOnly() throws {
        let asked = try #require(SquashCommitMessage(subject: "Ship the thing").instruction(proposed: .proposed(for: pullRequest)))
        #expect(asked.contains("`--subject`"))
        #expect(!asked.contains("--body"))
        #expect(asked.contains("```\nShip the thing\n```"))
    }

    @Test("a body is passed as --body, fenced so its own backticks cannot close the block")
    func withBody() throws {
        let message = SquashCommitMessage(subject: "Ship it (#12)", body: "Uses ```code``` here")
        let asked = try #require(message.instruction(proposed: .proposed(for: pullRequest)))
        #expect(asked.contains("`--body`"))
        #expect(asked.contains("````\nUses ```code``` here\n````"))
    }

    @Test("the direct merge passes the edited message as gh flags, a leading dash included")
    func mergeArguments() throws {
        let message = SquashCommitMessage(subject: "  -v is a subject ", body: " Why \n")
        let edited = try #require(message.edited(from: .proposed(for: pullRequest)))
        #expect(edited.mergeArguments == ["--subject=-v is a subject", "--body=Why"])
        #expect(SquashCommitMessage(subject: "Ship").mergeArguments == ["--subject=Ship"])
    }

    @Test("a body under the proposed subject is still an edit, and keeps that subject")
    func bodyOnly() throws {
        let proposed = SquashCommitMessage.proposed(for: pullRequest)
        let edited = try #require(SquashCommitMessage(subject: proposed.subject, body: "Why").edited(from: proposed))
        #expect(edited == SquashCommitMessage(subject: "Ship it (#12)", body: "Why"))
    }

    @Test("on GitLab the proposal is the bare title, and the agent is asked for --squash-message")
    func gitLab() throws {
        let merge = PullRequest(number: 12, title: "Ship it", url: "", state: "opened", forge: .gitLab)
        let proposed = SquashCommitMessage.proposed(for: merge)
        #expect(proposed == SquashCommitMessage(subject: "Ship it"))

        let message = SquashCommitMessage(subject: "Ship the thing", body: "Why")
        #expect(message.commitMessage == "Ship the thing\n\nWhy")
        let asked = try #require(message.instruction(proposed: proposed, forge: .gitLab))
        #expect(asked.contains("`--squash-message` to `glab mr merge`"))
        #expect(asked.contains("```\nShip the thing\n\nWhy\n```"))
    }
}
