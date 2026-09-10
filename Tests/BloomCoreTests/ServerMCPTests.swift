import Foundation
import Testing
import Synchronization
import BloomClient
@testable import BloomCore

@Suite("Standalone server MCP", .tags(.persistence, .subprocess), .scratchDirectory)
struct ServerMCPTests {
    @Test func daemonRegistersExistingToolsAndDeliversCancellableWorkspaceUICalls() async throws {
        let directory = TestScratch.unique("mcp-daemon")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try Store(path: ServerDaemon.databasePath(directory: directory))
        let repo = try await store.upsert(Repo(name: "fixture", path: directory, defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Fixture", branch: "fixture", path: directory, baseBranch: "main"))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let daemon = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: directory, installedAgents: { _ in [] })
        do {
            let attachment = daemon.bridge.attach(session: session, workspace: workspace, shimPath: "/fixture/bloom-bridge")
            let connection = try UnixSocketConnection.connect(to: daemon.bridge.socketPath)
            defer { connection.close() }
            var lines = connection.lines.makeAsyncIterator()
            connection.writeLine(String(decoding: try JSONEncoder().encode(BridgeHello(token: attachment.token, role: "parent")), as: UTF8.self))
            let hello = try #require(await lines.next())
            #expect(try JSONDecoder().decode(BridgeWelcome.self, from: Data(hello.utf8)).accepted)
            connection.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            let listed = try #require(await lines.next())
            let names = Set(JSONValue.parse(Data(listed.utf8))?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
            #expect(Set(["workspace_start", "workspace_archive", "agent_start", "agent_say", "agent_stop", "pane_open", "browser_text", "terminal_start"]).isSubset(of: names))

            #expect(!names.contains("workspace_merge"))
            let owner = try UnixSocketConnection.connect(to: daemon.bridge.socketPath)
            defer { owner.close() }
            var ownerLines = owner.lines.makeAsyncIterator()
            let ownerHello = BridgeHello(token: try daemon.bridge.ownerToken.load(), role: "owner")
            owner.writeLine(String(decoding: try JSONEncoder().encode(ownerHello), as: UTF8.self))
            _ = try #require(await ownerLines.next())
            owner.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            let ownerListed = try #require(await ownerLines.next())
            let ownerNames = JSONValue.parse(Data(ownerListed.utf8))?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
            #expect(ownerNames.contains("workspace_merge"))
            #expect(!ownerNames.contains("pane_open"))

            let attached = await daemon.runtime.respond(to: ServerRequest(.uiBridge(.attach(workspaceID: workspace.id, clientID: UUID(), actions: ["pane_open"]))))
            guard case .uiBridge(.attached(let lease)) = attached.result else { Issue.record("Could not attach fixture client"); await daemon.shutdown(); return }
            connection.writeLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pane_open","arguments":{"kind":"browser","url":"http://localhost:3190"}}}"#)
            let pending = await daemon.runtime.respond(to: ServerRequest(.uiBridge(.poll(leaseID: lease.id, token: lease.token, wait: true))))
            guard case .uiBridge(.requests(let batch)) = pending.result else { Issue.record("Missing UI batch"); await daemon.shutdown(); return }
            let request = try #require(batch.requests.first)
            #expect(request.workspaceID == workspace.id)
            #expect(request.action.name == "pane_open")
            #expect(request.action.arguments["url"] == .string("http://localhost:3190"))
            connection.writeLine(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#)
            let cancelled = try #require(await lines.next())
            #expect(JSONValue.parse(Data(cancelled.utf8))?["result"]?["isError"] == .bool(true))
            let late = await daemon.runtime.respond(to: ServerRequest(.uiBridge(.respond(leaseID: lease.id, token: lease.token, requestID: request.id, result: .init(text: "too late")))))
            guard case .failure = late.result else { Issue.record("Cancelled UI request accepted a late result"); await daemon.shutdown(); return }
            await daemon.shutdown()
        } catch {
            await daemon.shutdown()
            throw error
        }
    }

    @Test(arguments: [12, 13])
    func macClientNegotiatesOlderServerBeforeSendingTheOriginalMutation(version: Int) async throws {
        let directory = TestScratch.unique("legacy-mcp-client")
        let received = ServerMCPRequests()
        let listener = try UnixSocketListener(path: ServerDaemon.socketPath(directory: directory)) { connection in
            Task {
                defer { connection.close() }
                for await line in connection.lines {
                    guard let request = try? JSONDecoder().decode(ServerRequest.self, from: Data(line.utf8)) else { return }
                    received.values.withLock { $0.append(request) }
                    let result: ServerResult
                    if request.version != version {
                        result = .failure("Incompatible Bloom server protocol. Update the client and server.")
                    } else if case .hello = request.operation {
                        result = .hello(name: "Legacy fixture")
                    } else { result = .accepted }
                    var reply = ServerReply(id: request.id, result: result)
                    reply.version = version
                    guard let encoded = try? JSONEncoder().encode(reply) else { return }
                    connection.writeLine(String(decoding: encoded, as: UTF8.self))
                }
            }
        }
        defer { listener.stop() }
        let client = try await ServerClient.connect(to: .local(directory: directory))
        do {
            let command = ServerRequest(.send(sessionID: SessionID("fixture"), text: "Exactly once"))
            let reply = try await client.request(command)
            #expect(reply.id == command.id)
            #expect(reply.version == version)
            let service = RemoteWorkspaceService(client: client)
            await #expect(throws: ConnectionRefusal.self) {
                try await service.uiBridge(.attach(workspaceID: WorkspaceID("fixture"), clientID: UUID(), actions: []))
            }
            let requests = received.values.withLock { $0 }
            #expect(requests.map(\.version) == [14, version, version])
            #expect(requests.last?.id == command.id)
            #expect(requests.filter { $0.id == command.id }.count == 1)
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    @Test(arguments: [12, 13, 14])
    func compatibleRequestsKeepTheirReplyVersion(version: Int) async throws {
        let store = try makeTestStore("mcp-version")
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, installedAgents: { _ in [] })
        var request = ServerRequest(.catalogue)
        request.version = version
        let reply = await runtime.respond(to: request)
        #expect(reply.version == version)
        if case .catalogue = reply.result {} else { Issue.record("Compatible catalogue was refused") }
        await runtime.shutdown()
    }
}

private final class ServerMCPRequests: Sendable {
    let values = Mutex<[ServerRequest]>([])
}
