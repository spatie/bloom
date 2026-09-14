import Testing
import Foundation
@testable import BloomCore

/// The panel once a project offers prompts of its own: the owner's first, the project's under
/// them, one search over both, and nothing a project wrote ever sending itself.
@Suite("Quick prompt panel matches")
struct QuickPromptPanelMatchesTests {
    private static let mine = [
        QuickPrompt(name: "Run the tests", text: "Run the test suite and fix failures."),
        QuickPrompt(name: "Ship it", text: "Open a pull request.", sendsImmediately: true),
    ]
    private static let project = [
        ProjectQuickPrompt(name: "Check for N+1 queries", text: "Look for N+1 queries in the tests."),
        ProjectQuickPrompt(name: "Write the changelog", text: "Add a changelog entry.", opensNewChat: true),
    ]

    @Test("an empty query lists the owner's prompts first and the project's after, as stored")
    func emptyQueryKeepsSections() {
        let matches = QuickPromptPanelMatches.ranking(personal: Self.mine, project: Self.project, query: "  ")
        #expect(matches.query.isEmpty)
        #expect(matches.rows == Self.mine.map(QuickPromptPanelRow.personal) + Self.project.map(QuickPromptPanelRow.project))
    }

    @Test("one query searches both sections, and the owner's hits stay above the project's")
    func searchCoversBoth() {
        let matches = QuickPromptPanelMatches.ranking(personal: Self.mine, project: Self.project, query: "tests")
        // The project's prompt names nothing about tests but says it in the body, and the owner's
        // names it: both are kept, each in its own section.
        #expect(matches.personal.map(\.name) == ["Run the tests"])
        #expect(matches.project.map(\.name) == ["Check for N+1 queries"])
        #expect(matches.rows.map(\.name) == ["Run the tests", "Check for N+1 queries"])

        let changelog = QuickPromptPanelMatches.ranking(personal: Self.mine, project: Self.project, query: "changelog")
        #expect(changelog.personal.isEmpty)
        #expect(changelog.rows.map(\.name) == ["Write the changelog"])

        let nothing = QuickPromptPanelMatches.ranking(personal: Self.mine, project: Self.project, query: "zzz")
        #expect(nothing.isEmpty)
    }

    @Test("the arrows walk from the owner's section into the project's and wrap")
    func steppingCrossesSections() {
        let matches = QuickPromptPanelMatches.ranking(personal: Self.mine, project: Self.project, query: "")
        let rows = matches.rows
        #expect(matches.stepped(from: nil, by: 1) == rows.first)
        #expect(matches.stepped(from: rows[1], by: 1) == rows[2])
        #expect(matches.stepped(from: rows[3], by: 1) == rows[0])
        #expect(matches.stepped(from: rows[0], by: -1) == rows[3])
    }

    @Test("a highlighted project row survives the file being read again, by its name")
    func projectRowSurvivesReload() {
        let before = QuickPromptPanelMatches.ranking(personal: [], project: Self.project, query: "")
        let highlighted = before.rows[1]

        var reread = Self.project
        reread[1] = ProjectQuickPrompt(name: "Write the changelog", text: "Add an entry, reworded.")
        let after = QuickPromptPanelMatches.ranking(personal: Self.mine, project: reread, query: "")

        #expect(after.settled(after: highlighted) == .project(reread[1]))
        #expect(after.settled(after: nil) == after.rows.first)
    }

    @Test("an owner's prompt and a project's with the same name are different rows")
    func idsDoNotCollide() {
        let personal = QuickPromptPanelRow.personal(QuickPrompt(name: "Review", text: "a"))
        let shared = QuickPromptPanelRow.project(ProjectQuickPrompt(name: "Review", text: "a"))
        #expect(personal.id != shared.id)
    }

    @Test("a project prompt never sends, and opens a chat only where one can be opened")
    func projectDeliveryNeverSends() {
        #expect(Self.project[0].delivery(canOpenNewChat: true) == .compose)
        #expect(Self.project[1].delivery(canOpenNewChat: true) == .composeInNewChat)
        #expect(Self.project[1].delivery(canOpenNewChat: false) == .compose)
        for prompt in Self.project {
            #expect(!prompt.delivery(canOpenNewChat: true).sends)
        }
    }

    @Test("copying a project prompt gives the owner a prompt of their own that does not send")
    func copyToMyQuickPrompts() {
        let prompt = ProjectQuickPrompt(
            name: "Write the changelog", text: "Add an entry.", symbol: "cylinder", opensNewChat: true
        )
        #expect(prompt.personalFields == QuickPrompt.Fields(
            name: "Write the changelog", symbol: "cylinder", text: "Add an entry.",
            sendsImmediately: false, opensNewChat: true
        ))
        #expect(prompt.chatTitle == "Write the changelog")
    }
}
