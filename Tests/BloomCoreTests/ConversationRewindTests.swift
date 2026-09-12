import Foundation
import Testing
@testable import BloomCore

@Suite("Conversation rewind")
struct ConversationRewindTests {
    private func client(_ box: ProcessBox) -> CodexClient {
        CodexClient(configuration: .init(cwd: "/tmp/rewind-peer"), makeProcess: box.factory)
    }

    @Test("Legacy rollback counts actual provider turns from the selected ID")
    func legacy() async throws {
        let box = ProcessBox()
        box.reply(to: "thread/read", with: .object(["thread": .object([
            "id": .string("thread"), "historyMode": .string("legacy"),
            "turns": .array(["first", "selected", "last"].map { .object(["id": .string($0)]) }),
        ])]))
        let client = client(box)
        try await client.start()
        try await client.rewindThread(threadID: "thread", beforeTurnID: "selected")
        let sent = try #require(box.process.sentFrame { $0["method"]?.stringValue == "thread/rollback" })
        #expect(sent["params"]?["numTurns"]?.intValue == 2)
        #expect(!box.process.sentMethods.contains("thread/revert"))
        await client.stop()
    }

    @Test("Paginated rollback uses an exact boundary and does not call the deprecated endpoint")
    func paginated() async throws {
        let box = ProcessBox()
        box.reply(to: "thread/read", with: .object(["thread": .object([
            "id": .string("thread"), "historyMode": .string("paginated"),
        ])]))
        let client = client(box)
        try await client.start()
        try await client.rewindThread(threadID: "thread", beforeTurnID: "selected")
        let sent = try #require(box.process.sentFrame { $0["method"]?.stringValue == "thread/revert" })
        #expect(sent["params"]?["beforeTurnId"]?.stringValue == "selected")
        #expect(!box.process.sentMethods.contains("thread/rollback"))
        await client.stop()
    }

    @Test("A missing legacy boundary never sends a mutating request")
    func missingBoundary() async throws {
        let box = ProcessBox()
        box.reply(to: "thread/read", with: .object(["thread": .object([
            "id": .string("thread"), "turns": .array([.object(["id": .string("other")])]),
        ])]))
        let client = client(box)
        try await client.start()
        await #expect(throws: ConversationRewindError.self) {
            try await client.rewindThread(threadID: "thread", beforeTurnID: "selected")
        }
        #expect(!box.process.sentMethods.contains("thread/rollback"))
        await client.stop()
    }

    @Test("Recovery distinguishes absent turns from malformed pages and repeated cursors")
    func recoveryPage() async throws {
        let box = ProcessBox()
        box.reply(to: "thread/read", with: .object(["thread": .object([
            "id": .string("thread"), "historyMode": .string("paginated"),
        ])]))
        box.reply(to: "thread/turns/list", with: .object([
            "data": .array([]), "nextCursor": .null,
        ]))
        let client = client(box)
        try await client.start()
        #expect(try await client.threadContainsTurn(threadID: "thread", turnID: "selected") == false)
        box.process.reply(to: "thread/turns/list", with: .object(["data": .array([])]))
        await #expect(throws: ConversationRewindError.self) {
            _ = try await client.threadContainsTurn(threadID: "thread", turnID: "selected")
        }
        box.process.reply(to: "thread/turns/list", with: .object([
            "data": .array([]), "nextCursor": .string("repeated"),
        ]))
        await #expect(throws: ConversationRewindError.self) {
            _ = try await client.threadContainsTurn(threadID: "thread", turnID: "selected")
        }
        await client.stop()
    }
}
