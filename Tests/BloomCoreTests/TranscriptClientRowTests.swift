import Foundation
import Testing
@testable import BloomCore

@Suite("Client transcript rows")
struct TranscriptClientRowTests {
    @Test("session init metadata is omitted from the client transcript")
    func sessionInitIsHidden() {
        let stored = message(
            .system,
            #"{"type":"system","subtype":"init","session_id":"s1","model":"opus"}"#
        )
        #expect(TranscriptClientRow.present(stored)?.title == nil)
    }

    private func message(_ kind: MessageKind, _ payload: String, seq: Int = 1) -> Message {
        Message(sessionID: .new(), seq: seq, kind: kind, payload: Data(payload.utf8))
    }

    @Test("agent prose uses Bloom's Markdown parser and escapes active markup")
    func prose() {
        let stored = message(
            .assistantText,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"**Ready** <script>run()</script>"}]}}"#
        )
        let row = TranscriptClientRow.present(stored)
        #expect(row?.kind == .assistant)
        #expect(row?.html?.contains("<strong>Ready</strong>") == true)
        #expect(row?.html?.contains("<script>") == false)
        #expect(row?.html?.contains("&lt;script&gt;") == true)
    }

    @Test("a tool call and result carry one reference and readable content")
    func toolAndResult() {
        let call = message(
            .toolUse,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/repo/notes.md"}}]}}"#
        )
        let result = message(
            .toolResult,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"<ok>"}]}}"#,
            seq: 2
        )
        let callRow = TranscriptClientRow.present(call, worktree: "/repo")
        let resultRow = TranscriptClientRow.present(result, worktree: "/repo")
        #expect(callRow?.kind == .tool)
        #expect(callRow?.title == "Read")
        #expect(callRow?.detail.contains("notes.md") == true)
        #expect(callRow?.refID == "toolu_1")
        #expect(callRow?.files.first?.path == "notes.md")
        #expect(resultRow?.kind == .toolResult)
        #expect(resultRow?.refID == "toolu_1")
        #expect(resultRow?.text == "<ok>")
    }

    @Test("source references use the Mac transcript's path resolver")
    func sourceReferences() {
        let stored = message(
            .assistantText,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"See Sources/Bloom/App.swift:42 and /outside/secret.swift:3"}]}}"#
        )
        let row = TranscriptClientRow.present(stored, worktree: "/repo")
        #expect(row?.files.map(\.path) == ["Sources/Bloom/App.swift"])
        #expect(row?.files.first?.line == 42)
    }

    @Test("inline code and Markdown links expose files through the shared source rule")
    func markdownFiles() {
        let stored = message(
            .assistantText,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Open `Sources/Bloom/App.swift` or [the parser](Sources/BloomCore/Transcript/MarkdownParser.swift#L11)."}]}}"#
        )
        let row = TranscriptClientRow.present(stored, worktree: "/repo")
        #expect(row?.files.map(\.path) == ["Sources/Bloom/App.swift", "Sources/BloomCore/Transcript/MarkdownParser.swift"])
        #expect(row?.files.last?.line == 11)
    }

    @Test("browser question rows carry the same choices as the Mac card")
    func questionChoices() {
        let stored = message(.permissionAsk, #"{"type":"control_request","request_id":"ask-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","options":[{"label":"SQLite","description":"One file"},{"label":"Postgres"}]}]}}}"#)
        let row = TranscriptClientRow.present(stored)
        #expect(row?.canAnswer == true)
        #expect(row?.questions.first?.text == "Which database?")
        #expect(row?.questions.first?.options.map(\.label) == ["SQLite", "Postgres"])
        #expect(row?.questions.first?.options.first?.detail == "One file")
    }

    @Test("plan approval rows carry an implementation mode")
    func planApproval() {
        let stored = message(.permissionAsk, #"{"type":"control_request","request_id":"plan-1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{}}}"#)
        let row = TranscriptClientRow.present(stored)
        #expect(row?.canAnswer == true)
        #expect(row?.planMode == PermissionMode.acceptEdits.rawValue)
    }

    @Test("the browser sees attachment chips without their scratch paths in the bubble")
    func attachments() throws {
        let text = AttachmentTrailer.compose(
            text: "Please inspect this", paths: [".bloom/attachments/one/chart.png"]
        )
        let payload = try JSONSerialization.data(withJSONObject: ["message": ["content": [["text": text]]]])
        let stored = Message(sessionID: .new(), seq: 1, kind: .user, payload: payload)
        let row = TranscriptClientRow.present(stored)
        #expect(row?.text == "Please inspect this")
        #expect(row?.chips == ["chart.png"])
    }

    @Test("inline attachments remain openable in the browser transcript")
    func inlineAttachment() throws {
        let text = "Inspect `.bloom/attachments/ABC123/shot.png`"
        let payload = try JSONSerialization.data(withJSONObject: ["message": ["content": [["text": text]]]])
        let stored = Message(sessionID: .new(), seq: 1, kind: .user, payload: payload)
        let row = TranscriptClientRow.present(stored, worktree: "/repo")
        #expect(row?.files.first?.path == ".bloom/attachments/ABC123/shot.png")
        #expect(row?.files.first?.label == "`.bloom/attachments/ABC123/shot.png`")
    }

    @Test("silent stream events do not become empty client rows")
    func silentSystem() {
        let stored = message(.system, #"{"type":"stream_event","event":{"type":"content_block_delta"}}"#)
        let row = TranscriptClientRow.present(stored)
        #expect(row?.kind == nil)
    }
}
