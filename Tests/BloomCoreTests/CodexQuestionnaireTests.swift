import Testing
import Foundation
@testable import BloomCore

@Suite struct CodexQuestionnaireTests {
    private func request() -> CodexApprovalRequest {
        CodexApprovalRequest(
            id: .number(42), kind: .toolUserInput, threadID: "thread", turnID: "turn", itemID: "item",
            params: .object(["questions": .array([
                .object([
                    "id": .string("scope"), "header": .string("Scope"), "question": .string("Which one?"),
                    "options": .array([.object(["label": .string("All"), "description": .string("All screens")])]),
                ]),
                .object([
                    "id": .string("theme"), "header": .string("Theme"), "question": .string("Which one?"),
                    "isOther": .bool(true),
                    "options": .array([.object(["label": .string("Both"), "description": .string("Both themes")])]),
                ]),
                .object(["id": .string("secret"), "question": .string("A private answer?"), "isSecret": .bool(true)]),
            ])])
        )
    }

    @Test func usesTheSharedQuestionCardWithoutGrantingPermissions() throws {
        let ask = CodexPermission.ask(for: request(), item: nil)
        #expect(ask.isQuestion)
        #expect(ask.requiresUserInteraction)
        #expect(ask.suppressesAlwaysAllow)
        #expect(ask.suggestions.isEmpty)
        let restored = try #require(PermissionAsk.decode(payload: ask.raw))
        #expect(restored.input == ask.input)
        #expect(restored.isQuestion)
        let questions = AgentQuestionnaire.questions(in: restored.input)
        #expect(questions.map(\.id) == ["scope", "theme", "secret"])
        #expect(questions.map(\.allowsOther) == [false, true, true])
        #expect(questions.last?.isSecret == true)
    }

    @Test func duplicateWordingKeepsSeparateAnswersAndProducesTheCodexWireShape() {
        let input = CodexQuestionnaire.input(for: request())
        let questions = AgentQuestionnaire.questions(in: input)
        var draft = AgentQuestionDraft()
        draft.toggle("All", on: questions[0])
        draft.toggle("Both", on: questions[1])
        draft.other["secret"] = "private"
        let answers = draft.answers(to: questions)
        #expect(AgentQuestionnaire.isComplete(questions, answers: answers))
        let answered = AgentQuestionnaire.answered(input, answers: answers)
        let result = CodexQuestionnaire.result(input: answered, request: request())
        #expect(result["answers"]?["scope"]?["answers"] == .array([.string("All")]))
        #expect(result["answers"]?["theme"]?["answers"] == .array([.string("Both")]))
        #expect(result["answers"]?["secret"]?["answers"] == .array([.string("private")]))
    }

    @Test func ignoresUnknownAndBlankAnswers() {
        let result = CodexQuestionnaire.result(
            input: .object(["answers": .object(["scope": .string("  "), "unrelated": .string("injected")])]),
            request: request()
        )
        #expect(result == .object(["answers": .object([:])]))
        #expect(CodexApprovalDecision.decline.result(for: .toolUserInput) == .object(["answers": .object([:])]))
    }
}
