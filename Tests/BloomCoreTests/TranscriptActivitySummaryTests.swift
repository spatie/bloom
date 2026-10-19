import Testing
@testable import BloomCore

@Suite("Transcript activity summaries")
struct TranscriptActivitySummaryTests {
    @Test("Claude file calls and Codex patches use their declared paths")
    func toolClassification() {
        let edit = AgentToolUse(
            id: "edit", name: "Edit", input: .object(["file_path": .string("a.php")])
        )
        if case .edit(let paths) = TranscriptActivitySummary.Action.of(edit) {
            #expect(paths == ["a.php"])
        } else {
            Issue.record("Edit did not classify as a file change")
        }

        let patch = CodexItem.fileChange(CodexFileChange(id: "patch", changes: [
            CodexFileUpdate(path: "a.php", diff: "+a", kind: .add),
            CodexFileUpdate(path: "b.php", diff: "+b", kind: .add),
        ]))
        let use = AgentToolUse(
            id: "patch", name: "ApplyPatch", input: CodexTranslation.input(for: patch)
        )
        if case .edit(let paths) = TranscriptActivitySummary.Action.of(use) {
            #expect(paths == ["a.php", "b.php"])
        } else {
            Issue.record("Codex patch did not classify as a file change")
        }
    }

    @Test("edits count distinct files and retain the running command")
    func filesAndCommand() {
        let calls: [TranscriptActivitySummary.Call] = [
            .init(action: .edit(["a.php", "b.php"])),
            .init(action: .edit(["a.php"])),
            .init(action: .command, isRunning: true),
        ]
        #expect(TranscriptActivitySummary.label(calls) == "Edited 2 files, running 1 command")
    }

    @Test("one shell call has a summary in both running and completed states")
    func singleCommand() {
        let use = AgentToolUse(
            id: "shell", name: "Bash", input: .object(["command": .string("echo hello")])
        )
        #expect(TranscriptActivitySummary.singleCallLabel(use, isRunning: false) == "Ran 1 command")
        #expect(TranscriptActivitySummary.singleCallLabel(use, isRunning: true) == "Running 1 command")
    }

    @Test("MCP calls use a tool count even when there is only one")
    func calledTools() {
        let use = AgentToolUse(
            id: "mail", name: "mcp__\(BridgeRegistration.serverName)__mail_send", input: .object([:])
        )
        #expect(TranscriptActivitySummary.singleCallLabel(use, isRunning: false) == "Called 1 tool")
        #expect(TranscriptActivitySummary.singleCallLabel(use, isRunning: true) == "Called 1 tool")
        #expect(TranscriptActivitySummary.label([
            .init(action: .of(use)), .init(action: .of(use)),
        ]) == "Called 2 tools")

        let codex = CodexItem.mcpToolCall(CodexMcpToolCall(
            id: "codex-mail", server: BridgeRegistration.serverName, tool: "mail_send"
        ))
        let codexUse = AgentToolUse(
            id: "codex-mail", name: "CallTool", input: CodexTranslation.input(for: codex)
        )
        #expect(TranscriptActivitySummary.singleCallLabel(codexUse, isRunning: false) == "Called 1 tool")
    }

    @Test("searches, commands, reads and pages use their own nouns")
    func mixedWork() {
        let calls: [TranscriptActivitySummary.Call] = [
            .init(action: .search),
            .init(action: .command),
            .init(action: .read(["a.php", "b.php"])),
            .init(action: .webPage),
        ]
        #expect(TranscriptActivitySummary.label(calls)
            == "Ran 1 search, ran 1 command, explored 2 files, explored 1 web page")
    }

    @Test("unknown work falls back to a tool count")
    func unknownWork() {
        #expect(TranscriptActivitySummary.label([.init(action: .other)]) == "Used 1 tool")
        #expect(TranscriptActivitySummary.label([]) == nil)
    }
}
