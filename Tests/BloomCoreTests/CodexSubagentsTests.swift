import Testing
import Foundation
@testable import BloomCore

@Suite struct CodexSubagentsTests {
    @Test func aChildSnapshotUsesTheSharedTranscriptWithoutInventingToolCompletion() throws {
        let thread = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"id":"child","turns":[{"id":"turn","items":[
          {"type":"userMessage","id":"brief","content":[{"type":"text","text":"Review this change"}]},
          {"type":"agentMessage","id":"answer","text":"I am checking the tests"},
          {"type":"commandExecution","id":"shell","command":"swift test","status":"inProgress"}
        ]}]}
        """#.utf8))
        let transcript = CodexSubagentTranscript.read(thread, sessionID: SessionID("parent"))
        #expect(transcript.prompt == "Review this change")
        #expect(transcript.messages.contains { $0.kind == .assistantText })
        #expect(!transcript.messages.contains { $0.kind == .toolResult })
    }

    private func activity(_ id: String, child: String = "child", kind: String = "started") -> CodexEvent {
        .itemCompleted(CodexItemEvent(
            item: .subAgentActivity(CodexSubAgentActivity(
                id: id, agentPath: "/root/component_audit", agentThreadID: child, kind: kind
            )), threadID: "parent", turnID: "parent-turn", raw: Data()
        ))
    }

    @Test func aChildUsesTheSharedRosterAndCanResumeWithoutDuplicatingItsRow() throws {
        var tracker = CodexSubagents()
        var roster = SubagentRoster()
        for signal in tracker.receive(activity("spawn"), parentThreadID: "parent") { roster.apply(signal) }
        #expect(roster.isWorking)
        let duplicate = tracker.receive(activity("spawn"), parentThreadID: "parent")
        #expect(duplicate.isEmpty)
        for signal in tracker.receive(activity("done", kind: "completed"), parentThreadID: "parent") {
            roster.apply(signal)
        }
        #expect(!roster.isWorking)
        let turn = CodexTurn(id: "next", threadID: "child", status: .inProgress)
        for signal in tracker.receive(.turnStarted(turn), parentThreadID: "parent") { roster.apply(signal) }
        #expect(roster.isWorking)
        let child = try #require(roster[CodexSubagents.id(for: "child")])
        #expect(child.description == "component_audit")
        #expect(child.finishedAt == nil)
    }

    @Test func neverCreatesAChildForRootAndNeverTrustsAnUnrelatedThread() {
        var tracker = CodexSubagents()
        let root = tracker.receive(activity("root", child: "parent", kind: "interacted"), parentThreadID: "parent")
        #expect(root.isEmpty)
        #expect(tracker.threadID(for: CodexSubagents.id(for: "unrelated")) == nil)
        let other = tracker.receive(.turnStarted(CodexTurn(id: "x", threadID: "other", status: .inProgress)), parentThreadID: "parent")
        #expect(other.isEmpty)
    }

    @Test func aParentFinishingDoesNotFinishItsChild() {
        var tracker = CodexSubagents()
        var roster = SubagentRoster()
        for signal in tracker.receive(activity("spawn"), parentThreadID: "parent") { roster.apply(signal) }
        let ended = tracker.receive(.turnCompleted(CodexTurn(id: "parent-turn", threadID: "parent", status: .completed)), parentThreadID: "parent")
        for signal in ended { roster.apply(signal) }
        #expect(roster.isWorking)
        #expect(ended.isEmpty)
    }
}
