import Foundation
import Testing
@testable import BloomCore

@Suite("Chat tools", .tags(.persistence), .scratchDirectory)
struct ChatToolTests {
    private func seed(_ store: Store) async throws -> (Workspace, Session, BridgeIdentity) {
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Test", branch: "test", path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Current"))
        let identity = BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .parent)
        return (workspace, session, identity)
    }

    private func request(_ arguments: [String: JSONValue] = [:]) -> MCPRequest {
        MCPRequest(id: .integer(1), method: "chat_read", params: .object(arguments))
    }

    private func read(_ store: Store, _ identity: BridgeIdentity, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let result = await ChatReadTool().call(request(arguments), as: identity, store: store)
        #expect(!result.isError, "\(result.text)")
        return try #require(JSONValue.parse(result.text))
    }

    @Test("chat discovery and reads are served only to workspace parents")
    func gates() {
        for name in ["chat_list", "chat_read"] {
            #expect(BridgeToolbox.standard.handler(named: name, for: .parent) != nil)
            #expect(BridgeToolbox.standard.handler(named: name, for: .child) == nil)
            #expect(BridgeToolbox.standard.handler(named: name, for: .owner) == nil)
            #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + name))
        }
    }

    @Test("list identifies the current chat and reading a neighbouring chat returns its actual prose")
    func neighbouringChat() async throws {
        let store = try makeTestStore("chat-neighbour")
        let (workspace, current, identity) = try await seed(store)
        let neighbour = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat", agentKind: .codex))
        try await store.append(Message(sessionID: neighbour.id, seq: 0, kind: .user, payload: Data(
            #"{"type":"user","message":{"content":[{"type":"text","text":"Please explain\nthe fix."}]}}"#.utf8
        )))
        try await store.append(Message(sessionID: neighbour.id, seq: 1, kind: .assistantText, payload: Data(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Keep the actor isolated."}]}}"#.utf8
        )))
        let listed = await ChatListTool().call(request(), as: identity, store: store)
        let chats = try #require(JSONValue.parse(listed.text)?["chats"]?.arrayValue)
        #expect(chats.count == 2)
        #expect(chats.first { $0["id"] == .string(current.id.rawValue) }?["current"] == .bool(true))
        #expect(chats.first { $0["id"] == .string(neighbour.id.rawValue) }?["messages"] == .integer(2))
        for selector in ["Chat", neighbour.id.rawValue] {
            let page = try await read(store, identity, ["chat": .string(selector)])
            let messages = try #require(page["messages"]?.arrayValue)
            #expect(messages.map { $0["content"] } == [.string("Please explain\nthe fix."), .string("Keep the actor isolated.")])
            #expect(messages.map { $0["kind"] } == [.string("user"), .string("assistantText")])
            #expect(page.objectValue?["next_cursor"] == .null)
        }
    }

    @Test("duplicate titles require an ID, and another workspace's ID or title cannot be read")
    func scopeAndAmbiguity() async throws {
        let store = try makeTestStore("chat-scope")
        let (workspace, _, identity) = try await seed(store)
        let first = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let (_, outside, _) = try await seed(store)
        try await store.update(sessionID: outside.id) { $0.title = "Outside" }
        for selector in ["Chat", "Outside", outside.id.rawValue, "missing"] {
            let result = await ChatReadTool().call(request(["chat": .string(selector)]), as: identity, store: store)
            #expect(result.isError)
        }
        let page = try await read(store, identity, ["chat": .string(first.id.rawValue)])
        #expect(page["messages"] == .array([]))
        #expect(page.objectValue?["next_cursor"] == .null)
        let listed = await ChatListTool().call(request(), as: identity, store: store)
        #expect(!listed.text.contains(outside.id.rawValue))
    }

    @Test("message pagination preserves sequence gaps and includes messages appended between pages")
    func pagination() async throws {
        let store = try makeTestStore("chat-pages")
        let (_, session, identity) = try await seed(store)
        for seq in [0, 4, 8] {
            try await store.append(Message(sessionID: session.id, seq: seq, kind: .toolResult, payload: Data("result \(seq)".utf8)))
        }
        let first = try await read(store, identity, ["chat": .string("Current"), "limit": .integer(2)])
        #expect(first["messages"]?.arrayValue?.map { $0["seq"] } == [.integer(0), .integer(4)])
        let cursor = try #require(first["next_cursor"]?.stringValue)
        try await store.append(Message(sessionID: session.id, seq: 9, kind: .notice, payload: Data("later".utf8)))
        let second = try await read(store, identity, ["chat": .string(session.id.rawValue), "cursor": .string(cursor)])
        #expect(second["messages"]?.arrayValue?.map { $0["seq"] } == [.integer(8), .integer(9)])
        #expect(second.objectValue?["next_cursor"] == .null)
    }

    @Test("a large Unicode message is recoverable in full across bounded pages")
    func largeMessage() async throws {
        let store = try makeTestStore("chat-large")
        let (_, session, identity) = try await seed(store)
        let content = String(repeating: "👩🏽‍💻 café\n", count: 10_000)
        try await store.append(Message(sessionID: session.id, seq: 0, kind: .toolResult, payload: Data(content.utf8)))
        try await store.append(Message(sessionID: session.id, seq: 1, kind: .assistantText, payload: Data("Finished".utf8)))
        var arguments: [String: JSONValue] = ["chat": .string(session.id.rawValue)]
        var recovered = ""
        var sequences: [Int] = []
        var finished = false
        for _ in 0..<10 {
            let page = try await read(store, identity, arguments)
            let messages = try #require(page["messages"]?.arrayValue)
            let size = messages.reduce(0) { $0 + ($1["content"]?.stringValue?.count ?? 0) }
            #expect(size <= ChatTranscriptPage.characterLimit)
            for message in messages {
                if message["seq"] == .integer(0) {
                    #expect(message["offset"] == .integer(recovered.count))
                    recovered += try #require(message["content"]?.stringValue)
                }
                if message["complete"] == .bool(true), let seq = message["seq"]?.intValue { sequences.append(seq) }
            }
            guard let cursor = page["next_cursor"]?.stringValue else { finished = true; break }
            arguments["cursor"] = .string(cursor)
        }
        #expect(finished)
        #expect(recovered == content)
        #expect(sequences == [0, 1])
    }

    @Test("an empty title is found under the name shown in the tab strip")
    func untitledChat() async throws {
        let store = try makeTestStore("chat-untitled")
        let (workspace, _, identity) = try await seed(store)
        let untitled = try await store.upsert(Session(workspaceID: workspace.id, title: ""))
        let page = try await read(store, identity, ["chat": .string(PaneNaming.untitledChat)])
        #expect(page["chat_id"] == .string(untitled.id.rawValue))
        #expect(page["title"] == .string(PaneNaming.untitledChat))
    }

    @Test("closed chats are excluded while crew conversations remain readable")
    func archivedAndCrew() async throws {
        let store = try makeTestStore("chat-archived")
        let (workspace, current, identity) = try await seed(store)
        let archived = try await store.upsert(Session(workspaceID: workspace.id, title: "Closed"))
        try await store.update(sessionID: archived.id) { $0.archivedAt = Date() }
        var crew = Session(workspaceID: workspace.id, title: "Reviewer")
        crew.parentSessionID = current.id
        try await store.upsert(crew)
        let listed = await ChatListTool().call(request(), as: identity, store: store)
        let chats = try #require(JSONValue.parse(listed.text)?["chats"]?.arrayValue)
        #expect(chats.count == 2)
        #expect(chats.first { $0["id"] == .string(crew.id.rawValue) }?["parent_chat_id"] == .string(current.id.rawValue))
        let result = await ChatReadTool().call(request(["chat": .string(archived.id.rawValue)]), as: identity, store: store)
        #expect(result.isError)
        let page = try await read(store, identity, ["chat": .string(crew.id.rawValue)])
        #expect(page["chat_id"] == .string(crew.id.rawValue))
    }

    @Test("tool JSON, unknown records and multi-block assistant messages retain their payload")
    func preservedPayloads() throws {
        let sessionID = SessionID.new()
        let payloads: [(MessageKind, String)] = [
            (.toolUse, #"{"name":"Bash","input":{"command":"ls"}}"#),
            (.toolResult, #"{"content":"one\ntwo","is_error":false}"#),
            (.assistantText, #"{"type":"assistant","message":{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}}"#),
            (.notice, "Unknown legacy record"),
        ]
        let messages = payloads.enumerated().map { index, pair in
            Message(sessionID: sessionID, seq: index, kind: pair.0, payload: Data(pair.1.utf8))
        }
        let page = try ChatTranscriptPage.make(messages: messages, cursor: .init(sessionID: sessionID), limit: 50)
        #expect(page.messages.map { $0["content"]?.stringValue } == payloads.map { $0.1 })
        #expect(page.nextCursor?.rawValue == nil)
    }

    @Test("malformed pagination and cursors for another chat are refused")
    func invalidArguments() async throws {
        let store = try makeTestStore("chat-arguments")
        let (_, session, identity) = try await seed(store)
        for invalid: JSONValue in [.integer(0), .integer(101), .number(1.5), .string("2"), .bool(true), .null] {
            let result = await ChatReadTool().call(request(["chat": .string("Current"), "limit": invalid]), as: identity, store: store)
            #expect(result.isError)
        }
        for cursor in ["bad", "other:0:0", "\(session.id):0:-1", "\(session.id):-1:0", "\(session.id):0:1"] {
            let result = await ChatReadTool().call(request(["chat": .string("Current"), "cursor": .string(cursor)]), as: identity, store: store)
            #expect(result.isError)
        }
        let missing = await ChatReadTool().call(request(), as: identity, store: store)
        #expect(missing.isError)
        let owner = await ChatReadTool().call(request(["chat": .string("Current")]), as: .owner, store: store)
        #expect(owner.isError)
    }
}
