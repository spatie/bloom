import Foundation
import Testing
@testable import BloomClient

struct ApprovalTests {
    private func request(tool: String = "Bash", input: JSONValue = .object(["command": .string("ls")]), interaction: Bool = false) throws -> RemoteApproval {
        let data = try JSONEncoder().encode(JSONValue.object([
            "type": .string("control_request"), "request_id": .string("ask"),
            "request": .object(["subtype": .string("can_use_tool"), "tool_name": .string(tool), "input": input,
                                "requires_user_interaction": .bool(interaction)])
        ]))
        return try #require(RemoteApproval(data: data))
    }

    @Test func unsupportedConsentCannotProduceAllowOrDeny() throws {
        for tool in ["ExitPlanMode", "mcp__service__tool", "Codex.permissions", "UnknownTool"] {
            let approval = try request(tool: tool)
            #expect(!approval.isSupported)
            #expect(throws: ConnectionFailure.self) { try approval.decision(sessionID: SessionID("s"), allow: true) }
        }
        #expect(try !request(interaction: true).isSupported)
        #expect(try !request(input: .object([:])).isSupported)
        #expect(RemoteApproval(data: Data(#"{"type":"other"}"#.utf8)) == nil)
    }

    @Test func questionsPreserveInputAndUseSharedAnswerRules() throws {
        let input: JSONValue = .object(["extra": .string("preserved"), "questions": .array([
            .object(["question": .string("Which?"), "bloomAnswerID": .string("codex-id"), "multiSelect": .bool(true),
                     "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])])])])])
        let approval = try request(tool: "AskUserQuestion", input: input, interaction: true)
        #expect(approval.isSupported)
        var draft = AgentQuestionDraft()
        #expect(throws: ConnectionFailure.self) { try approval.answer(sessionID: SessionID("s"), draft: draft) }
        draft.toggle("B", on: approval.questions[0]); draft.toggle("A", on: approval.questions[0])
        let command = try approval.answer(sessionID: SessionID("s"), draft: draft)
        let answered = command.operation["answer"]?["answer"]?["question"]?["input"]
        #expect(answered?["answers"]?["codex-id"]?.stringValue == "A, B")
        #expect(answered?["extra"]?.stringValue == "preserved")
        #expect(throws: ConnectionFailure.self) { try approval.decision(sessionID: SessionID("s"), allow: true) }
    }

    @Test func malformedOrDuplicateQuestionsStayUnsupported() throws {
        let question: JSONValue = .object(["question": .string("Same")])
        for questions: [JSONValue] in [[question, question], [question, .object([:])], [],
                                      [.object(["question": .string("Bad option"), "options": .array([.object([:])])])],
                                      [.object(["question": .string("Private"), "isSecret": .string("true")])]] {
            #expect(try !request(tool: "AskUserQuestion", input: .object(["questions": .array(questions)])).isSupported)
        }
    }

    @Test func codexRestrictedChoicesCannotBeReplacedWithFreeText() throws {
        let input: JSONValue = .object(["questions": .array([.object([
            "question": .string("Choose"), "bloomAnswerID": .string("id"), "bloomAllowsOther": .bool(false),
            "options": .array([.object(["label": .string("One")])])
        ])])])
        let approval = try request(tool: "AskUserQuestion", input: input, interaction: true)
        var draft = AgentQuestionDraft()
        draft.other["id"] = "Unoffered"
        #expect(throws: ConnectionFailure.self) { try approval.answer(sessionID: SessionID("s"), draft: draft) }
    }

    @Test func missingCodexCommandAndPatchDetailsCannotBeApproved() throws {
        #expect(try !request(tool: "Shell", input: .object(["itemId": .string("missing")])).isSupported)
        #expect(try !request(tool: "ApplyPatch", input: .object(["grantRoot": .string("/project")])).isSupported)
        let input: JSONValue = .object(["codexItem": .object(["changes": .array([
            .object(["path": .string("file.swift"), "diff": .string("-old\n+new")])
        ])])])
        let approval = try request(tool: "ApplyPatch", input: input)
        #expect(approval.isSupported)
        #expect(approval.context.contains("file.swift"))
        #expect(approval.context.contains("-old"))
    }
}
