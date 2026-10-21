import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab vocabulary")
struct GitLabVocabularyTests {
    @Test("a GitLab merge request has a pipeline of jobs, a GitHub pull request has checks")
    func pipeline() {
        let failing: (Forge) -> PullRequest = { forge in
            PullRequest(
                number: 1, title: "", url: "", state: "OPEN", checks: .failing,
                checksSummary: "1 required check failed", forge: forge
            )
        }
        #expect(failing(.gitHub).status.text == "Checks failing")
        #expect(failing(.gitLab).status.text == "Pipeline failing")
        #expect(WorkspaceStatus.checksFailing.label(for: .gitHub) == "Checks failing")
        #expect(WorkspaceStatus.checksFailing.label(for: .gitLab) == "Pipeline failing")
        #expect(WorkspaceStatus.draft.label(for: .gitLab) == "Draft merge request")
        #expect(WorkspaceStatus.clean.label(for: .gitLab) == WorkspaceStatus.clean.label)
    }
}

@Suite("GitLab turns in the transcript")
struct GitLabSentTurnTests {
    @Test("a GitLab merge turn shows its rules as a chip, like GitHub's")
    func mergeTurnChip() {
        let turn = ProjectInstructions.turn("Merge merge request !1 into main.", for: .merge, adding: .nothing, forge: .gitLab)
        #expect(SentTurn.withoutInstructions(turn) == "Merge merge request !1 into main.")
        #expect(SentTurn.title(forFile: GitLabInstructions.mergeRequestScratchPath) == SentTurn.mergeRequestTitle)
    }
}

@Suite("GitLab tool descriptions")
struct GitLabToolDescriptionTests {
    private static let tools = [
        WorkspaceListTool().tool,
        WorkspaceMergeTool(read: { _ in .noPullRequest }) { _, _, _ in .turnBegun(chat: "Merge") }.tool,
        WorkspaceStartTool(start: { _, _, _, _ in throw CancellationError() }).tool,
    ]

    @Test("an agent in a GitLab workspace is told about glab and merge requests, in the same schema")
    func gitLabListings() throws {
        for tool in Self.tools {
            let listing = GitLabInstructions.listing(of: tool)
            let text = BridgeToolResult.json(listing).text
            expectCharacterised(text, "gitlab-tool-\(tool.name).json")
            #expect(!text.contains("`gh "))
            #expect(!text.localizedCaseInsensitiveContains("pull request"))
            guard case .object(let fields) = listing, case .object(let original) = tool.listing else {
                Issue.record("A listing is an object")
                continue
            }
            #expect(fields["name"] == original["name"])
            #expect(Set(propertyNames(fields["inputSchema"])) == Set(propertyNames(original["inputSchema"])))
        }
    }

    private func propertyNames(_ schema: JSONValue?) -> [String] {
        guard case .object(let fields) = schema, case .object(let properties) = fields["properties"] else { return [] }
        return Array(properties.keys)
    }
}
