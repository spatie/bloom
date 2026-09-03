import Foundation
import Testing
@testable import BloomCore

/// The real `bloom-bridge` binary, launched as a subprocess and spoken to on its stdin exactly as
/// an agent CLI speaks to an MCP server.
///
/// `Tools/test-core.sh` builds the shim into the throwaway package and names it in
/// `BLOOM_BRIDGE_SHIM`; without that there is nothing to drive, and these are skipped the way the
/// live suites are. A shim exercised only by another test would prove nothing about the process a
/// CLI actually starts, which is the half of this feature most likely to be wrong.
private let shimPath = BridgeRegistration.shimPath()

@Suite("BridgeShim", .enabled(if: shimPath != nil), .tags(.subprocess), .scratchDirectory)
struct BridgeShimTests {
    private func launch(_ environment: [String: String]) throws -> StreamingProcess {
        let process = StreamingProcess(
            executable: try #require(shimPath),
            arguments: [],
            cwd: NSTemporaryDirectory(),
            environment: environment,
            mergeStderr: false
        )
        try process.start()
        return process
    }

    /// A socket short enough for `sun_path`, in the process's own directory. Not
    /// `BridgeSocketPath.derive`, because that answers for a database and these tests have none,
    /// and not the running test's own directory either: that is a `bloom-scratch-` plus a whole
    /// UUID, which with a name on the end runs past the 104 bytes `sun_path` holds. The process
    /// root is short, and it is swept when the run ends, which is what these used to skip: one
    /// abandoned `.sock` per test per run. See `TestProcessScratch`.
    private func scratchSocket() -> String {
        (TestProcessScratch.root as NSString)
            .appendingPathComponent("shim-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test("relays a whole MCP conversation between its stdin and the app", .timeLimit(.minutes(1)))
    func relaysAConversation() async throws {
        let store = try makeTestStore("shim")
        let repo = try await store.upsert(Repo(name: "billing", path: "/tmp/billing"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "cut the index",
            branch: "bloom/cut-the-index",
            path: "/tmp/billing-cut",
            baseBranch: "main",
            origin: .user
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        let socketPath = scratchSocket()
        let server = BridgeServer(store: store, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let attachment = server.attach(
            session: session,
            workspace: workspace,
            shimPath: try #require(shimPath)
        )
        let process = try launch(attachment.environment)
        defer { process.terminate() }

        var replies = process.lines.makeAsyncIterator()
        process.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let initialized = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(try #require(try await replies.next()).utf8)
        )
        #expect(initialized["result"]?["serverInfo"]?["name"] == .string(BridgeRegistration.serverName))

        process.writeLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        process.writeLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"whoami","arguments":{}}}"#)
        let called = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(try #require(try await replies.next()).utf8)
        )
        // The notification in between was answered with silence, or this would be its reply.
        #expect(called["id"] == .integer(2))

        let text = try #require(called["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.contains("cut the index"))
        #expect(text.contains("bloom/cut-the-index"))
        #expect(text.contains("billing"))
    }

    @Test("closing its stdin ends the process, so no shim outlives the CLI that started it",
          .timeLimit(.minutes(1)))
    func stdinCloseEndsIt() async throws {
        let store = try makeTestStore("shim-exit")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "w",
            branch: "b",
            path: "/tmp/w",
            baseBranch: "main",
            origin: .user
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        let server = BridgeServer(store: store, socketPath: scratchSocket())
        try server.start()
        defer { server.stop() }

        let attachment = server.attach(
            session: session,
            workspace: workspace,
            shimPath: try #require(shimPath)
        )
        let process = try launch(attachment.environment)
        process.closeStdin()
        #expect(await process.exitStatus == BridgeShim.Exit.ok)
    }

    @Test("says so and exits when it is run without an environment", .timeLimit(.minutes(1)))
    func withoutAnEnvironment() async throws {
        let process = try launch(["PATH": "/usr/bin:/bin"])
        var complaints: [String] = []
        for await line in process.errorLines { complaints.append(line) }

        #expect(await process.exitStatus == BridgeShim.Exit.notConfigured)
        #expect(complaints.joined(separator: " ").contains(BridgeProtocol.socketVariable))
    }

    /// The complaint used to say "Neither was set" whichever of the two was missing, which sent
    /// the reader to check the one variable that was already right.
    @Test("it names the variable that is missing rather than blaming both")
    func namesTheMissingVariable() {
        #expect(BridgeShim.missingEnvironment([
            BridgeProtocol.socketVariable: "/tmp/a.sock",
            BridgeProtocol.tokenVariable: "t",
        ]) == nil)

        let noToken = try! #require(BridgeShim.missingEnvironment([BridgeProtocol.socketVariable: "/tmp/a.sock"]))
        #expect(noToken.contains("\(BridgeProtocol.tokenVariable) was not set"))
        #expect(!noToken.contains("Neither"))

        let noSocket = try! #require(BridgeShim.missingEnvironment([BridgeProtocol.tokenVariable: "t"]))
        #expect(noSocket.contains("\(BridgeProtocol.socketVariable) was not set"))

        // An empty value is not a value, and it is what an unset variable in a plist looks like.
        let blank = try! #require(BridgeShim.missingEnvironment([
            BridgeProtocol.socketVariable: "",
            BridgeProtocol.tokenVariable: "t",
        ]))
        #expect(blank.contains("\(BridgeProtocol.socketVariable) was not set"))

        #expect(BridgeShim.missingEnvironment([:])?.contains("Neither was set") == true)
    }

    @Test("names the socket it could not reach, rather than hanging", .timeLimit(.minutes(1)))
    func withoutAnApp() async throws {
        let socketPath = scratchSocket()
        let process = try launch([
            BridgeProtocol.socketVariable: socketPath,
            BridgeProtocol.tokenVariable: "t",
            BridgeProtocol.roleVariable: "parent",
        ])
        var complaints: [String] = []
        for await line in process.errorLines { complaints.append(line) }

        #expect(await process.exitStatus == BridgeShim.Exit.cannotReachBloom)
        #expect(complaints.joined(separator: " ").contains(socketPath))
    }

    /// Bloom quitting with a call in flight. The shim used to exit 0 and write nothing anywhere,
    /// which is the same thing it does when the CLI asks it to shut down, so the CLI was told the
    /// server had finished normally while the answer it was waiting for never arrived. A tool call
    /// that never answers and never complains is a turn that cannot end.
    @Test("says so and fails when Bloom goes away with a call in flight", .timeLimit(.minutes(1)))
    func bloomQuitsMidCall() async throws {
        let socketPath = scratchSocket()
        let welcome = String(
            decoding: try JSONEncoder().encode(BridgeWelcome.accepting()),
            as: UTF8.self
        )
        let listener = try UnixSocketListener(path: socketPath) { connection in
            Task {
                var incoming = connection.lines.makeAsyncIterator()
                _ = await incoming.next()
                connection.writeLine(welcome)
                // The call arrives, and then Bloom is gone without having answered it.
                _ = await incoming.next()
                connection.close()
            }
        }
        defer { listener.stop() }

        let process = try launch([
            BridgeProtocol.socketVariable: socketPath,
            BridgeProtocol.tokenVariable: "t",
            BridgeProtocol.roleVariable: "parent",
        ])
        defer { process.terminate() }
        process.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami"}}"#)

        var complaints: [String] = []
        for await line in process.errorLines { complaints.append(line) }

        // stdin is still open here, which is what tells the shim this was not a shutdown.
        #expect(await process.exitStatus == BridgeShim.Exit.cannotReachBloom)
        #expect(complaints.joined(separator: " ").contains("before answering"))
    }

    /// The Sparkle case, from the shim's side: the bundle was replaced underneath a running Bloom,
    /// the CLI launched the new binary, and the app on the socket does not speak its protocol. The
    /// requirement is a sentence and an exit, never a hang, because a tool call that never answers
    /// is a turn that never ends and the model cannot tell the two apart.
    @Test("prints Bloom's refusal and exits when the protocol does not match", .timeLimit(.minutes(1)))
    func refusedAtTheHandshake() async throws {
        let socketPath = scratchSocket()
        let refusal = BridgeWelcome.refusing("Bloom speaks 1 and this bloom-bridge speaks 2. Quit and reopen Bloom.")
        let encoded = String(decoding: try JSONEncoder().encode(refusal), as: UTF8.self)
        let listener = try UnixSocketListener(path: socketPath) { connection in
            Task {
                var incoming = connection.lines.makeAsyncIterator()
                _ = await incoming.next()
                connection.writeLine(encoded)
                connection.close()
            }
        }
        defer { listener.stop() }

        let process = try launch([
            BridgeProtocol.socketVariable: socketPath,
            BridgeProtocol.tokenVariable: "t",
            BridgeProtocol.roleVariable: "parent",
        ])
        var complaints: [String] = []
        for await line in process.errorLines { complaints.append(line) }

        #expect(await process.exitStatus == BridgeShim.Exit.refused)
        #expect(complaints.joined(separator: " ").contains("Quit and reopen Bloom"))
    }
}
