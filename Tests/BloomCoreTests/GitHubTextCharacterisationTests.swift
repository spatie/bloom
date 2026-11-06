import Foundation
import Testing
@testable import BloomCore

/// What Bloom tells an agent about pull requests, word for word. `isUnedited` compares defaults
/// byte for byte, so a reworded default makes every untouched copy look edited.
@Suite("GitHub texts, as they stand")
struct GitHubTextCharacterisationTests {
    @Test("every default prompt", arguments: PromptRegistry.all)
    func prompt(_ definition: PromptDefinition) {
        let variables = definition.variables.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
        let text = """
        title: \(definition.title)

        summary:
        \(definition.summary)

        variables:
        \(variables)

        template:
        \(definition.defaultTemplate)
        """
        expectCharacterised(text, "prompt-\(definition.id.rawValue).txt")
    }

    @Test("the instruction files Bloom writes")
    func instructionFiles() {
        expectCharacterised(PullRequestInstructions.defaultMarkdown, "pr-instructions.md")
        expectCharacterised(MergeInstructions.canonical, "merge-instructions.md")
        expectCharacterised(ConflictInstructions.defaultMarkdown, "conflict-instructions.md")
        for (index, retired) in PullRequestInstructions.retiredDefaults.enumerated() {
            expectCharacterised(retired, "pr-instructions-retired-\(index + 1).md")
        }
    }

    @Test("the sentences that carry a project's own instructions")
    func projectInstructionSentences() {
        let subjects: [ProjectInstructions.Subject] = [.merge, .fixConflicts]
        let text = subjects.flatMap { subject in
            [
                ProjectInstructions.sentence(for: subject, adding: .file(".bloom/scratch/instructions.md")) ?? "",
                ProjectInstructions.sentence(for: subject, adding: .inline("Squash it.")) ?? "",
            ]
        }.joined(separator: "\n---\n")
        expectCharacterised(text, "project-instruction-sentences.txt")
    }

    @Test("the sentence a failed check is handed to the agent with")
    func checkFailureSentence() {
        let text = [
            CheckFailureHandoff.sentence(
                name: "Tests", workflow: "CI", state: .failed,
                detailsURL: "https://github.com/acme/app/actions/runs/1/job/2",
                logPath: ".bloom/scratch/checks/tests.log"
            ),
            CheckFailureHandoff.sentence(name: "Lint", state: .failed),
        ].joined(separator: "\n---\n")
        expectCharacterised(text, "check-failure-sentence.txt")
    }

    @Test("the tools an agent sees for pull requests")
    func toolListings() {
        let tools = [
            WorkspaceListTool().tool,
            WorkspaceMergeTool(read: { _ in .noPullRequest }) { _, _, _ in .turnBegun(chat: "Merge") }.tool,
            WorkspaceStartTool(start: { _, _, _, _ in throw CancellationError() }).tool,
        ]
        for tool in tools {
            expectCharacterised(BridgeToolResult.json(tool.listing).text, "tool-\(tool.name).json")
        }
    }
}
