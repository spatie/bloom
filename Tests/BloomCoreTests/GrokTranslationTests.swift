import Testing
import Foundation
@testable import BloomCore

@Suite("Grok translation")
struct GrokTranslationTests {
    @Test("session ready becomes a stored init line naming Grok")
    func sessionReadyIsInit() {
        var translation = GrokTranslation(context: GrokTranslation.Context(
            model: "grok-4.6",
            cwd: "/tmp/w",
            permissionMode: "auto"
        ))
        let events = translation.translate(.sessionReady(GrokSession(
            id: "sess-1",
            currentModelID: "grok-4.6"
        )))
        guard case .initialized(let value) = events.first else {
            Issue.record("expected init")
            return
        }
        #expect(value.sessionID == "sess-1")
        #expect(value.agentKind == .grok)
        #expect(value.model == "grok-4.6")
        let json = JSONValue.parse(value.raw)
        #expect(json?["type"]?.stringValue == "system")
        #expect(json?["agent_kind"]?.stringValue == "grok")
    }

    @Test("text chunks stream live and flush as one assistant row")
    func textChunksFlush() {
        var translation = GrokTranslation(context: GrokTranslation.Context(model: "grok-4.6"))
        _ = translation.translate(.sessionReady(GrokSession(id: "sess-1")))
        let first = translation.translate(.update(GrokSessionUpdate(
            sessionID: "sess-1",
            kind: .text("Hel"),
            raw: .object([:])
        )))
        #expect(first.contains { if case .streamDelta(.text("Hel")) = $0 { return true }; return false })
        let second = translation.translate(.update(GrokSessionUpdate(
            sessionID: "sess-1",
            kind: .text("lo"),
            raw: .object([:])
        )))
        #expect(second.contains { if case .streamDelta(.text("lo")) = $0 { return true }; return false })
        let done = translation.translate(.promptCompleted(GrokPromptResult(
            requestID: .number(1),
            sessionID: "sess-1",
            stopReason: "end_turn",
            raw: .object([:])
        )))
        guard let text = done.compactMap({ event -> String? in
            if case .assistantText(let block) = event { return block.text }
            return nil
        }).first else {
            Issue.record("expected assistant text")
            return
        }
        #expect(text == "Hello")
        #expect(done.contains { if case .result(let result) = $0 { return !result.isError }; return false })
    }

    @Test("a tool call maps onto Read and carries the path Bloom already looks for")
    func toolCallMapsToRead() {
        var translation = GrokTranslation(context: GrokTranslation.Context(model: "grok-4.6"))
        _ = translation.translate(.sessionReady(GrokSession(id: "sess-1")))
        let call = GrokToolCall.decode(.object([
            "toolCallId": .string("call_1"),
            "title": .string("Read"),
            "kind": .string("read"),
            "status": .string("pending"),
            "toolName": .string("read_file"),
            "rawInput": .object(["path": .string("src/main.rs")]),
        ]), isUpdate: false)
        let events = translation.translate(.update(GrokSessionUpdate(
            sessionID: "sess-1",
            kind: .toolCall(call),
            raw: .object([:])
        )))
        guard case .toolUse(let use) = events.first else {
            Issue.record("expected tool use")
            return
        }
        #expect(use.id == "call_1")
        #expect(use.name == "Read")
        #expect(use.filePath == "src/main.rs")
        #expect(GrokTranslation.isGrokCall(use.input))
    }

    @Test("a finished tool update becomes a result row")
    func toolUpdateCompletes() {
        var translation = GrokTranslation(context: GrokTranslation.Context(model: "grok-4.6"))
        _ = translation.translate(.sessionReady(GrokSession(id: "sess-1")))
        let started = GrokToolCall.decode(.object([
            "toolCallId": .string("call_1"),
            "toolName": .string("run_terminal_cmd"),
            "status": .string("in_progress"),
            "rawInput": .object(["command": .string("echo hi")]),
        ]), isUpdate: false)
        _ = translation.translate(.update(GrokSessionUpdate(
            sessionID: "sess-1",
            kind: .toolCall(started),
            raw: .object([:])
        )))
        let finished = GrokToolCall.decode(.object([
            "toolCallId": .string("call_1"),
            "status": .string("completed"),
            "content": .array([.object([
                "type": .string("content"),
                "content": .object(["type": .string("text"), "text": .string("hi\n")]),
            ])]),
        ]), isUpdate: true)
        let events = translation.translate(.update(GrokSessionUpdate(
            sessionID: "sess-1",
            kind: .toolCallUpdate(finished),
            raw: .object([:])
        )))
        guard case .toolResult(let result) = events.first else {
            Issue.record("expected tool result")
            return
        }
        #expect(result.toolUseID == "call_1")
        #expect(result.text.contains("hi"))
        #expect(!result.isError)
    }

    @Test("permission options map allow_once onto Bloom's once")
    func permissionOptions() {
        let request = GrokPermissionRequest(
            id: .number(3),
            sessionID: "sess-1",
            toolCall: GrokToolCall.decode(.object([
                "toolCallId": .string("call_1"),
                "toolName": .string("run_terminal_cmd"),
                "rawInput": .object(["command": .string("ls")]),
            ]), isUpdate: false),
            options: [
                GrokPermissionOption(id: "allow-once", name: "Allow once", kind: "allow_once"),
                GrokPermissionOption(id: "reject-once", name: "Reject", kind: "reject_once"),
            ],
            raw: Data()
        )
        let ask = GrokPermission.ask(for: request)
        #expect(ask.requestID == "grok:sess-1:3")
        #expect(ask.toolName == "Bash")
        #expect(ask.input["command"]?.stringValue == "ls")
        #expect(ask.suppressesAlwaysAllow)
        #expect(GrokPermission.optionID(for: .allow(scope: .once), in: request) == "allow-once")
        #expect(GrokPermission.optionID(
            for: .deny(message: "no", endsTurn: false),
            in: request
        ) == "reject-once")
    }

    @Test("reject_always without allow_always does not offer Bloom's persistent grant")
    func rejectAlwaysDoesNotOfferAlwaysAllow() {
        let request = GrokPermissionRequest(
            id: .number(3),
            sessionID: "sess-1",
            toolCall: GrokToolCall.decode(.object([
                "toolCallId": .string("call_1"),
                "toolName": .string("read_file"),
                "rawInput": .object(["path": .string("a.rs")]),
            ]), isUpdate: false),
            options: [
                GrokPermissionOption(id: "allow-once", name: "Allow once", kind: "allow_once"),
                GrokPermissionOption(id: "reject-once", name: "Reject", kind: "reject_once"),
                GrokPermissionOption(id: "reject-always", name: "Always reject", kind: "reject_always"),
            ],
            raw: Data()
        )
        let ask = GrokPermission.ask(for: request)
        #expect(ask.suppressesAlwaysAllow)
        #expect(ask.suggestions.isEmpty)
        #expect(GrokPermission.optionID(for: .allow(scope: .session), in: request) == "allow-once")
    }
}
