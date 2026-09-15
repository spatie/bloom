import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory) struct CodexMcpResultTests {
    @Test func completedMcpResultSurvivesDecodingTranslationAndStorage() async throws {
        let image: JSONValue = .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("IMAGE_BASE64_SENTINEL")])
        let structured: JSONValue = .object(["heading": .string("Somewhere else"), "image": image])
        let content: [JSONValue] = [
            .object(["type": .string("text"), "text": .string("Visible heading")]),
            .object(["type": .string("resource"), "resource": .object(["uri": .string("bloom://page"), "text": .string("Rendered resource text")])]),
            image,
        ]
        let result: JSONValue = .object(["content": .array(content), "structuredContent": structured])
        let item = try decoded(result: result)
        guard case .mcpToolCall(let call) = item else { Issue.record("Expected MCP call"); return }
        #expect(call.result == result)
        #expect(CodexTranslation.json(of: item)["result"] == result)
        var translation = CodexTranslation()
        let event = try #require(translation.translate(.itemCompleted(CodexItemEvent(item: item, threadID: "thread", turnID: "turn"))).first)
        guard case .toolResult(let completed) = event else { Issue.record("Expected completed tool result"); return }
        #expect(completed.text.contains("Visible heading"))
        #expect(completed.text.contains("Rendered resource text"))
        #expect(completed.text.contains("Somewhere else"))
        #expect(!completed.text.contains("IMAGE_BASE64_SENTINEL"))
        #expect(completed.hasImages && !completed.isError)

        let store = try makeTestStore("codex-mcp-result")
        let session = try await store.upsert(Session(workspaceID: nil))
        try await store.appendNext(sessionID: session.id, kind: event.kind, payload: event.raw, refID: event.refID)
        let saved = try #require(try await store.messages(sessionID: session.id).first)
        let raw = try #require(JSONValue.parse(saved.payload))
        let block = try #require(raw["message"]?["content"]?[0])
        #expect(block["content"]?[2] == image)
        #expect(block["structuredContent"] == structured)
        #expect(saved.refID == "call" && saved.kind == MessageKind.toolResult)
        guard case .toolResult(let replay)? = AgentEvent.decode(line: String(decoding: saved.payload, as: UTF8.self)) else {
            Issue.record("Expected replayed tool result"); return
        }
        #expect(replay.text == completed.text && replay.hasImages && !replay.isError)
    }

    @Test func protocolAndMcpLevelErrorsKeepReadableDetailsAndErrorState() throws {
        for (result, status, error): (JSONValue?, String, String?) in [
            (.object(["content": .array([.object(["type": .string("text"), "text": .string("Tool failed")])]), "isError": .bool(true)]), "completed", nil),
            (nil, "failed", "Transport failed"),
        ] {
            let item = try decoded(result: result, status: status, error: error)
            var translation = CodexTranslation()
            guard case .toolResult(let completed)? = translation.translate(.itemCompleted(CodexItemEvent(item: item, threadID: "thread", turnID: "turn"))).first else {
                Issue.record("Expected tool result"); continue
            }
            #expect(completed.isError)
            #expect(completed.text.contains("failed"))
            guard case .toolResult(let replay)? = AgentEvent.decode(line: String(decoding: completed.raw, as: UTF8.self)) else {
                Issue.record("Expected replayed result"); continue
            }
            #expect(replay.isError && replay.text == completed.text)
        }
    }

    @Test func olderItemsAndInitializersWithoutResultStillWork() throws {
        let call = CodexMcpToolCall(id: "old", server: "bloom", tool: "browser_text")
        #expect(call.result == nil)
        #expect(CodexTranslation.resultText(for: .mcpToolCall(call)).isEmpty)
        guard case .mcpToolCall(let decoded) = try decoded(result: nil) else { Issue.record("Expected MCP call"); return }
        #expect(decoded.result == nil)
    }

    private func decoded(result: JSONValue?, status: String = "completed", error: String? = nil) throws -> CodexItem {
        let json = JSONValue.object(omittingNil: ["type": .string("mcpToolCall"), "id": .string("call"),
            "server": .string("bloom-workspace-bridge"), "tool": .string("browser_text"), "arguments": .object([:]),
            "status": .string(status), "result": result, "error": error.map { .object(["message": .string($0)]) }])
        return try #require(CodexItem.decode(json))
    }
}
