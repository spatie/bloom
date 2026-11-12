import Foundation
import Testing
@testable import BloomCore

/// Rewinding a Claude chat. The flags were measured against Claude Code 2.1.322; these hold
/// Bloom to pointing them at the right messages. See `ClaudeRewind`.
@Suite("Claude rewind", .scratchDirectory)
struct ClaudeRewindTests {
    private let session = SessionID("chat")

    private func row(_ seq: Int, _ kind: MessageKind, _ json: String) -> Message {
        Message(sessionID: session, seq: seq, kind: kind, payload: Data(json.utf8))
    }

    private func user(_ seq: Int, _ text: String, uuid: String? = nil) throws -> Message {
        row(seq, .user, try AgentRunner.encodeTurn(text, uuid: uuid))
    }

    private let first = "11111111-1111-4111-8111-111111111111"
    private let reply = "22222222-2222-4222-8222-222222222222"
    private let second = "33333333-3333-4333-8333-333333333333"
    private let subagent = "44444444-4444-4444-8444-444444444444"

    @Test("a turn line carries its uuid only when given one")
    func encodesTheUUID() throws {
        #expect(ClaudeRewind.messageUUID(in: Data(try AgentRunner.encodeTurn("hi", uuid: first).utf8)) == first)
        #expect(!(try AgentRunner.encodeTurn("hi")).contains("uuid"))
    }

    @Test("a delivered message is sent under its delivery id")
    func deliveryUUID() {
        #expect(ClaudeRewind.turnUUID(for: DeliveryID(first)) == first)
        let minted = ClaudeRewind.turnUUID(for: DeliveryID("not-a-uuid"))
        #expect(UUID(uuidString: minted) != nil)
        #expect(UUID(uuidString: ClaudeRewind.turnUUID(for: nil)) != nil)
    }

    @Test("rewinding to a later message resumes at the last main line before it and restores files from its own id")
    func planForALaterMessage() throws {
        let messages = [
            try user(0, "make a.txt", uuid: first),
            row(1, .assistantText, #"{"type":"assistant","uuid":"\#(reply)","parent_tool_use_id":null,"message":{}}"#),
            row(2, .toolResult, #"{"type":"user","uuid":"\#(subagent)","parent_tool_use_id":"toolu_1","message":{}}"#),
            row(3, .result, #"{"type":"result","uuid":"55555555-5555-4555-8555-555555555555"}"#),
            try user(4, "now change it", uuid: second),
            row(5, .assistantText, #"{"type":"assistant","uuid":"66666666-6666-4666-8666-666666666666","message":{}}"#),
        ]
        let plan = try #require(ClaudeRewind.plan(rewindingTo: 4, in: messages))

        // Not the subagent's line, which lives in its own file, and not the result, which is not
        // a line of the conversation at all.
        #expect(plan.resumeAt == reply)
        #expect(plan.fileRewindPoint == second)
        #expect(plan.removeFromSeq == 4)
        #expect(plan.prompt == "now change it")
    }

    @Test("rewinding to the first message starts a fresh conversation")
    func planForTheFirstMessage() throws {
        let plan = try #require(ClaudeRewind.plan(rewindingTo: 0, in: [try user(0, "hello", uuid: first)]))
        #expect(plan.resumeAt == nil)
        #expect(plan.fileRewindPoint == first)
    }

    @Test("a message sent before ids were kept still rewinds its conversation, but not its files")
    func planForAnOldMessage() throws {
        let messages = [
            row(0, .assistantText, #"{"type":"assistant","uuid":"\#(reply)","message":{}}"#),
            try user(1, "old"),
        ]
        let plan = try #require(ClaudeRewind.plan(rewindingTo: 1, in: messages))
        #expect(plan.resumeAt == reply)
        #expect(plan.fileRewindPoint == nil)
    }

    @Test("only the owner's own message can be rewound to")
    func onlyUserRows() {
        let messages = [row(0, .assistantText, #"{"type":"assistant","uuid":"\#(reply)","message":{}}"#)]
        #expect(ClaudeRewind.plan(rewindingTo: 0, in: messages) == nil)
        #expect(ClaudeRewind.plan(rewindingTo: 9, in: messages) == nil)
    }

    @Test("the resume point forks, and only when there is a conversation to resume")
    func argv() {
        let chat = Session(workspaceID: WorkspaceID("w"), title: "c", model: "sonnet")
        let forked = AgentRunner.argv(session: chat, resume: "old-session", resumeAt: reply)
        #expect(forked.suffix(5) == ["--resume", "old-session", "--resume-session-at", reply, "--fork-session"])
        #expect(!AgentRunner.argv(session: chat, resume: nil, resumeAt: reply).contains("--resume-session-at"))
        #expect(!AgentRunner.argv(session: chat, resume: "old-session").contains("--fork-session"))
    }

    @Test("restoring files is one call naming the session and the message, judged by what it prints")
    func fileRewind() {
        #expect(ClaudeRewind.fileRewindArguments(session: "s", to: first) == ["-p", "--resume", "s", "--rewind-files", first])
        #expect(ClaudeRewind.fileRewindSucceeded("Files rewound to state at message \(first)\n"))
        #expect(!ClaudeRewind.fileRewindSucceeded("Error: --rewind-files requires a user message UUID"))
    }

    @Test("a claimed delivery's row carries the id it will be sent under, and a rewind removes rows from a point on")
    func storeRows() async throws {
        let store = try makeTestStore("claude-rewind")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        let chat = try await store.upsert(Session(workspaceID: workspace.id, title: "c", model: "sonnet"))
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: chat.id, body: "queued words"))
        #expect(try await store.claimDelivery(id: delivery.id))

        let rows = try await store.messages(sessionID: chat.id)
        let claimed = try #require(rows.first)
        #expect(ClaudeRewind.messageUUID(in: claimed.payload) == delivery.id.rawValue)
        #expect(ClaudeRewind.text(of: claimed.payload) == "queued words")

        _ = try await store.appendNext(sessionID: chat.id, kind: .assistantText, payload: Data("{}".utf8))
        #expect(try await store.removeMessages(sessionID: chat.id, fromSeq: claimed.seq + 1) == 1)
        #expect(try await store.messages(sessionID: chat.id).map(\.seq) == [claimed.seq])
    }
}
