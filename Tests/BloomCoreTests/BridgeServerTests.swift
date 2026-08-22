import Foundation
import Testing
@testable import BloomCore

/// The bridge over a real unix socket, with a real store behind it.
///
/// Not a mocked transport talking to a mocked server. The socket, the handshake, the JSON-RPC and
/// the store reads are the whole of what phase one adds, and every one of them either works
/// against a real descriptor or does not work at all. What is deliberately NOT here is the
/// registration, which no test can prove: only a real `claude` or `codex` process reading a real
/// config file can say whether the flags are right. That is `LiveBridgeTests`.
@Suite("BridgeServer", .tags(.subprocess, .persistence), .scratchDirectory)
struct BridgeServerTests {
    /// A store holding one project, one workspace and one chat, and a server listening for it.
    private func makeBridge(
        origin: WorkspaceOrigin = .user
    ) async throws -> (server: BridgeServer, token: String, workspace: Workspace, session: Session) {
        let store = try makeTestStore("bridge")
        let repo = try await store.upsert(Repo(name: "billing", path: "/tmp/billing", defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "fix the index",
            branch: "bloom/fix-the-index",
            path: "/tmp/billing-fix-the-index",
            baseBranch: "main",
            origin: origin
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "First chat"))

        // The real derivation, against a database path unique to this test, so two tests running
        // at once cannot land on one socket. Which is also the property the derivation exists for.
        let server = try BridgeServer(store: store)
        try server.start()
        let attachment = server.attach(session: session, workspace: workspace, shimPath: "/tmp/bloom-bridge")
        return (server, attachment.token, workspace, session)
    }

    /// Speaks the socket protocol the way the shim does, and hands back whole lines.
    private struct Caller {
        let connection: UnixSocketConnection
        var iterator: AsyncStream<String>.AsyncIterator

        init(socketPath: String) throws {
            connection = try UnixSocketConnection.connect(to: socketPath)
            iterator = connection.lines.makeAsyncIterator()
        }

        mutating func hello(_ frame: BridgeHello) async throws -> BridgeWelcome {
            connection.writeLine(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self))
            let reply = try #require(await iterator.next())
            return try JSONDecoder().decode(BridgeWelcome.self, from: Data(reply.utf8))
        }

        mutating func call(_ request: String) async throws -> JSONValue {
            connection.writeLine(request)
            let reply = try #require(await iterator.next())
            return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        }
    }

    @Test("a whole MCP conversation, over the socket, answers whoami with this workspace")
    func endToEnd() async throws {
        let (server, token, workspace, session) = try await makeBridge()
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        let welcome = try await caller.hello(BridgeHello(token: token, role: "parent", shim: "test"))
        #expect(welcome.accepted)
        #expect(welcome.version == BridgeProtocol.version)

        let initialized = try await caller.call(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test","version":"0"}}}"#
        )
        #expect(initialized["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(initialized["result"]?["serverInfo"]?["name"] == .string(BridgeRegistration.serverName))
        // Whatever the client used for an id comes straight back. A reply carrying a number where
        // the request carried a string is a reply the client never matches up.
        #expect(initialized["id"] == .integer(1))

        let listed = try await caller.call(#"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#)
        #expect(listed["id"] == .string("two"))
        let names = listed["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["whoami"])

        let called = try await caller.call(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"whoami","arguments":{}}}"#
        )
        #expect(called["result"]?["isError"] == .bool(false))
        let text = try #require(called["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

        #expect(answer["workspace"]?["id"]?.stringValue == workspace.id.rawValue)
        #expect(answer["workspace"]?["name"]?.stringValue == "fix the index")
        #expect(answer["workspace"]?["branch"]?.stringValue == "bloom/fix-the-index")
        #expect(answer["project"]?["name"]?.stringValue == "billing")
        #expect(answer["session"]?["id"]?.stringValue == session.id.rawValue)
        #expect(answer["created_by"]?.stringValue == "owner")
        #expect(answer["role"]?.stringValue == "parent")

        caller.connection.close()
    }

    @Test("a spawned workspace answers as a child, with the parent that asked for it")
    func aChildKnowsItsParent() async throws {
        let parent = WorkspaceID("parent-1")
        let (server, token, _, _) = try await makeBridge(
            origin: .agent(parentWorkspaceID: parent, spawnToolUseID: "toolu_01")
        )
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        // The claimed role is a lie and is ignored: the answer comes off the workspace row.
        _ = try await caller.hello(BridgeHello(token: token, role: "parent", shim: "test"))
        let called = try await caller.call(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami"}}"#
        )
        let text = try #require(called["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

        #expect(answer["role"]?.stringValue == "child")
        #expect(answer["created_by"]?["agent_in_workspace"]?.stringValue == parent.rawValue)
        #expect(answer["created_by"]?["spawn_tool_use_id"]?.stringValue == "toolu_01")
        caller.connection.close()
    }

    /// Sparkle replaces the bundle underneath a running app, so a shim from a newer build can meet
    /// an older Bloom. The requirement is that it fails with a sentence rather than hanging, and
    /// that the sentence names both numbers and the remedy.
    @Test("a shim speaking another protocol version is refused, not left hanging")
    func versionSkew() async throws {
        let (server, token, _, _) = try await makeBridge()
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        let welcome = try await caller.hello(BridgeHello(
            version: BridgeProtocol.version + 7,
            token: token,
            role: "parent",
            shim: "/tmp/bloom-bridge"
        ))

        #expect(!welcome.accepted)
        let problem = try #require(welcome.problem)
        #expect(problem.contains("\(BridgeProtocol.version)"))
        #expect(problem.contains("\(BridgeProtocol.version + 7)"))
        #expect(problem.lowercased().contains("quit and reopen bloom"))

        // And the connection really is over, rather than left open for a caller to wait on.
        #expect(await caller.iterator.next() == nil)
    }

    @Test("a token this launch did not mint gets nowhere")
    func unknownToken() async throws {
        let (server, _, _, _) = try await makeBridge()
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        let welcome = try await caller.hello(BridgeHello(token: "made up", role: "child", shim: "x"))
        #expect(!welcome.accepted)
        #expect(welcome.problem?.contains("previous launch") == true)
    }

    @Test("a connection that starts talking MCP without a hello is refused")
    func noHandshake() async throws {
        let (server, _, _, _) = try await makeBridge()
        defer { server.stop() }

        let caller = try UnixSocketConnection.connect(to: server.socketPath)
        var iterator = caller.lines.makeAsyncIterator()
        caller.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let reply = try #require(await iterator.next())
        let welcome = try JSONDecoder().decode(BridgeWelcome.self, from: Data(reply.utf8))
        #expect(!welcome.accepted)
        caller.close()
    }

    @Test("a method the bridge does not implement is answered rather than ignored")
    func unknownMethod() async throws {
        let (server, token, _, _) = try await makeBridge()
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        _ = try await caller.hello(BridgeHello(token: token, role: "parent", shim: "test"))

        let reply = try await caller.call(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)
        #expect(reply["error"]?["code"] == .integer(MCPErrorCode.methodNotFound))

        let unknownTool = try await caller.call(
            #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"workspace_spawn"}}"#
        )
        #expect(unknownTool["error"]?["code"] == .integer(MCPErrorCode.methodNotFound))
        caller.connection.close()
    }

    /// A notification has no id and must be answered with silence. Sending a response to one is a
    /// protocol error the client may close the connection over, and `notifications/initialized` is
    /// the very first thing every MCP client sends.
    @Test("a notification is not replied to")
    func notificationsAreSilent() async throws {
        let (server, token, _, _) = try await makeBridge()
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        _ = try await caller.hello(BridgeHello(token: token, role: "parent", shim: "test"))

        caller.connection.writeLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        // The next line to arrive is the answer to the ping behind it, not an answer to the
        // notification in front of it.
        let reply = try await caller.call(#"{"jsonrpc":"2.0","id":42,"method":"ping"}"#)
        #expect(reply["id"] == .integer(42))
        #expect(reply["result"] != nil)
        caller.connection.close()
    }
}

/// `workspace_start` over the real socket, which is the only thing that proves an agent could
/// reach it: the toolbox, the role gate, the dispatch's argument unwrapping and the handler all
/// have to agree, and each of them is a separate place this could be wired up wrong.
@Suite("BridgeServer: starting workspaces", .tags(.subprocess, .persistence), .scratchDirectory)
struct BridgeWorkspaceStartTests {
    private struct Caller {
        let connection: UnixSocketConnection
        var iterator: AsyncStream<String>.AsyncIterator

        init(socketPath: String) throws {
            connection = try UnixSocketConnection.connect(to: socketPath)
            iterator = connection.lines.makeAsyncIterator()
        }

        mutating func hello(_ frame: BridgeHello) async throws -> BridgeWelcome {
            connection.writeLine(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self))
            let reply = try #require(await iterator.next())
            return try JSONDecoder().decode(BridgeWelcome.self, from: Data(reply.utf8))
        }

        mutating func call(_ request: String) async throws -> JSONValue {
            connection.writeLine(request)
            let reply = try #require(await iterator.next())
            return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        }
    }

    private final class Orders: @unchecked Sendable {
        var prompts: [String] = []
    }

    private func makeBridge(
        origin: WorkspaceOrigin = .user,
        orders: Orders,
        label: String
    ) async throws -> (server: BridgeServer, token: String) {
        let store = try makeTestStore(label)
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "group occurrences",
            branch: "claude/group-occurrences",
            path: "/tmp/flare-group",
            baseBranch: "main",
            origin: origin
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "First chat"))

        let toolbox = BridgeToolbox(handlers: [
            WhoamiTool(),
            WorkspaceStartTool { order, _, _ in
                orders.prompts.append(order.prompt)
                return StartedWorkspaceSummary(
                    workspaceID: WorkspaceID(rawValue: "w-new"),
                    name: "Sentry importer",
                    branch: "claude/sentry-importer",
                    path: "/tmp/worktrees/w-new"
                )
            },
        ])

        let server = try BridgeServer(store: store, toolbox: toolbox)
        try server.start()
        let attachment = server.attach(session: session, workspace: workspace, shimPath: "/tmp/bloom-bridge")
        return (server, attachment.token)
    }

    @Test("a parent lists the tool and calling it starts a workspace")
    func parentCanStartOne() async throws {
        let orders = Orders()
        let (server, token) = try await makeBridge(orders: orders, label: "bridge-start-parent")
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        #expect(try await caller.hello(BridgeHello(token: token, role: "parent", shim: "test")).accepted)

        let listing = try await caller.call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let names = (listing["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("workspace_start"))

        let call = try await caller.call(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workspace_start","arguments":{"prompt":"Import from Sentry"}}}
            """#)

        #expect(call["result"]?["isError"]?.boolValue == false)
        #expect(orders.prompts == ["Import from Sentry"])

        let text = call["result"]?["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(text.contains("w-new"))
        #expect(text.contains("claude/sentry-importer"))
    }

    /// A child is told the tool does not exist, in the same words an unknown name gets. A refusal
    /// that reads differently from "no such tool" tells the caller something is there.
    @Test("a child cannot see the tool and cannot call it either")
    func childIsRefusedTwice() async throws {
        let orders = Orders()
        let (server, token) = try await makeBridge(
            origin: .agent(parentWorkspaceID: WorkspaceID(rawValue: "w-parent"), spawnToolUseID: "t1"),
            orders: orders,
            label: "bridge-start-child"
        )
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        #expect(try await caller.hello(BridgeHello(token: token, role: "child", shim: "test")).accepted)

        let listing = try await caller.call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let names = (listing["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(!names.contains("workspace_start"))

        let call = try await caller.call(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workspace_start","arguments":{"prompt":"Import from Sentry"}}}
            """#)

        #expect(call["error"]?["code"]?.intValue == MCPErrorCode.methodNotFound)
        #expect(orders.prompts.isEmpty)
    }

    /// Three at once is the case the owner asked for by name, and the case a serial serve loop
    /// plus `WorktreeCutQueue` exist to survive.
    @Test("three starts in one turn all arrive, in order")
    func threeInOneTurn() async throws {
        let orders = Orders()
        let (server, token) = try await makeBridge(orders: orders, label: "bridge-start-three")
        defer { server.stop() }

        var caller = try Caller(socketPath: server.socketPath)
        #expect(try await caller.hello(BridgeHello(token: token, role: "parent", shim: "test")).accepted)

        for (index, prompt) in ["Import from Sentry", "Group by release", "Faster search"].enumerated() {
            let call = try await caller.call(#"""
                {"jsonrpc":"2.0","id":\#(index + 2),"method":"tools/call","params":{"name":"workspace_start","arguments":{"prompt":"\#(prompt)"}}}
                """#)
            #expect(call["result"]?["isError"]?.boolValue == false)
        }

        #expect(orders.prompts == ["Import from Sentry", "Group by release", "Faster search"])
    }
}
