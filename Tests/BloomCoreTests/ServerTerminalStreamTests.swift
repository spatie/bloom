import Foundation
import Testing
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import BloomCore

@Suite("ServerTerminalStream", .scratchDirectory, .tags(.subprocess, .persistence))
struct ServerTerminalStreamTests {
    @Test func shutdownRejectsLateStreamOpenAndRemovesExistingListeners() async throws {
        let streams = ServerTerminalStreams(groupID: nil)
        let workspace = Workspace(repoID: RepoID("fixture"), name: "Fixture", branch: "main", path: TestScratch.path("terminal-shutdown"), baseBranch: "main")
        let terminal = ServerTerminal(executable: "/bin/sh", socket: "/unused/socket", session: "fixture")
        let path = try await streams.open(terminal: terminal, workspace: workspace)
        await streams.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path))
        let late = try? await streams.open(terminal: terminal, workspace: workspace)
        #expect(late == nil)
        // Keep a deliberately failing regression run from leaving its late listener behind.
        await streams.shutdown()
    }

    @Test func shutdownWaitsForATerminalClientThatIgnoresTermination() async throws {
        let directory = TestScratch.unique("terminal-client-shutdown")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let ready = directory + "/ready"
        let process = StreamingProcess(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf ready > \"$1\"; while :; do sleep 1; done", "bloom-terminal-test", ready], cwd: directory)
        defer { process.kill() }
        let streams = ServerTerminalStreams(groupID: nil, makeProcess: { _, _ in process })
        let workspace = Workspace(repoID: RepoID("fixture"), name: "Fixture", branch: "main", path: directory, baseBranch: "main")
        let terminal = ServerTerminal(executable: "/bin/sh", socket: "/unused/socket", session: "fixture")
        let path = try await streams.open(terminal: terminal, workspace: workspace)
        let client = try UnixSocketConnection.connect(to: path)
        defer { client.close() }
        await waitUntil("fixture installed its TERM handler") { FileManager.default.fileExists(atPath: ready) }
        #expect(process.isRunning)
        await streams.shutdown()
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func shutdownInvalidatesAndDrainsAnInFlightTerminalStart() async throws {
        let directory = TestScratch.unique("terminal-start-shutdown")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], cwd: directory)
        defer { process.kill() }
        let gate = TerminalStartGate()
        let cancelled = Mutex(false)
        let finished = Mutex(false)
        let service = ServerTerminalService(ownsDaemon: true, makeProcess: { _, _ in process }, run: { _, arguments, _ in
            if arguments.first == "show-options" {
                await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.withLock { $0 = true } }
            }
            return ShellResult(status: 0, stdout: "", stderr: "")
        })
        let command = TmuxCommand(executable: "/unused/tmux", socketName: "fixture", configPath: directory + "/tmux.conf")
        let start = Task { () -> Bool in
            do { try await service.start(command: command, key: "fixture", cwd: directory); return true } catch { return false }
        }
        await waitUntil("terminal readiness probe is pending") { await gate.entered }
        let shutdown = Task { await service.shutdown(); finished.withLock { $0 = true } }
        await waitUntil("shutdown cancels the owned start") { cancelled.withLock { $0 } }
        #expect(!finished.withLock { $0 })
        await gate.release()
        let accepted = await start.value
        await shutdown.value
        #expect(!accepted)
        #expect(!process.isRunning)
        await #expect(throws: ServerFailure.self) { try await service.start(command: command, key: "late", cwd: directory) }
    }

    @Test func failedTerminalReadinessCleansUpItsOwnedProcess() async throws {
        let directory = TestScratch.unique("terminal-start-failure")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], cwd: directory)
        defer { process.kill() }
        let service = ServerTerminalService(ownsDaemon: true, makeProcess: { _, _ in process }, run: { _, _, _ in
            throw ServerFailure("Readiness failed")
        })
        let command = TmuxCommand(executable: "/unused/tmux", socketName: "fixture", configPath: directory + "/tmux.conf")
        await #expect(throws: ServerFailure.self) { try await service.start(command: command, key: "fixture", cwd: directory) }
        #expect(!process.isRunning)
        await service.shutdown()
    }

    @Test func controlOutputPreservesEscapeSequencesAndBinaryBytes() {
        var parser = TmuxControlOutput()
        let bytes = parser.take("%output %0 hello\\015\\012\\033[31m\\377")
        #expect(bytes == Data([104, 101, 108, 108, 111, 13, 10, 27, 91, 51, 49, 109, 255]))
        let begin = parser.take("%begin 123 1 0")
        #expect(begin == nil)
        let literal = parser.take("%output %0 this is captured text")
        #expect(literal == Data("%output %0 this is captured text\r\n".utf8))
        let end = parser.take("%end 123 1 0")
        #expect(end == nil)
    }

    @Test func reconnectRestoresScreenWithoutScrollingAndRestoresCursor() {
        var parser = TmuxControlOutput(restoringScreen: true)
        for number in 0...1 {
            _ = parser.take("%begin 123 \(number) 0")
            _ = parser.take("%end 123 \(number) 0")
        }
        _ = parser.take("%begin 123 2 0")
        _ = parser.take("previous output")
        _ = parser.take("$ ")
        let screen = parser.take("%end 123 2 0")
        #expect(screen == Data("\u{1b}[2J\u{1b}[Hprevious output\r\n$ ".utf8))
        _ = parser.take("%begin 123 3 0")
        _ = parser.take("2 1")
        let cursor = parser.take("%end 123 3 0")
        #expect(cursor == Data("\u{1b}[2;3H".utf8))
        let live = parser.take("%output %0 echo")
        #expect(live == Data("echo".utf8))
    }

    @Test func inputIsHexEncodedAndResizeIsBounded() {
        let input = ServerTerminalFrame(kind: "input", data: Data(";kill-server\r".utf8))
        let command = TmuxControlOutput.command(input, session: "owned")
        #expect(command == "send-keys -H -t =owned: 3b 6b 69 6c 6c 2d 73 65 72 76 65 72 0d")
        #expect(TmuxControlOutput.command(ServerTerminalFrame(kind: "resize", columns: 0, rows: 24), session: "owned") == nil)
        #expect(TmuxControlOutput.command(ServerTerminalFrame(kind: "input", data: Data(repeating: 1, count: 16_385)), session: "owned") == nil)
    }

    @Test func groupAccessIsExplicitAndOtherSocketsRemainPrivate() throws {
        let first = "/tmp/bloom-socket-test-\(UUID().uuidString).sock"
        let second = "/tmp/bloom-socket-test-\(UUID().uuidString).sock"
        let privateSocket = try UnixSocketListener(path: first) { $0.close() }
        let groupSocket = try UnixSocketListener(path: second, groupID: getgid()) { $0.close() }
        defer { privateSocket.stop(); groupSocket.stop() }
        let privateMode = try FileManager.default.attributesOfItem(atPath: first)[.posixPermissions] as? NSNumber
        let groupMode = try FileManager.default.attributesOfItem(atPath: second)[.posixPermissions] as? NSNumber
        #expect(privateMode?.intValue == 0o600)
        #expect(groupMode?.intValue == 0o660)
    }

    @Test func disconnectReattachesTheSameShellWithoutReplayingInput() async throws {
        guard let tmux = Shell.which("tmux") else { return }
        let repo = try await TempRepo()
        let store = try makeTestStore("terminal-stream")
        let storedRepo = try await store.upsert(Repo(name: "Terminal", path: repo.path))
        let workspace = try await store.upsert(Workspace(repoID: storedRepo.id, name: "Terminal", branch: "main", path: repo.path, baseBranch: "main"))
        let configuration = URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("tmux.conf")
        try (TmuxSessions.configuration(defaultShell: "/bin/sh") + "\nset -g default-command /bin/sh\n").write(to: configuration, atomically: true, encoding: .utf8)
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) })
        do {
            let first = await runtime.respond(to: ServerRequest(.terminalStream(workspaceID: workspace.id, name: "https")))
            guard case .text(let path) = first.result else { Issue.record("Terminal stream failed: \(first.result)"); await runtime.shutdown(); return }
            let connection = try UnixSocketConnection.connect(to: path)
            let command = ServerTerminalFrame(kind: "input", data: Data("printf 'first\\n' >> stream.txt\r".utf8))
            connection.writeLine(String(decoding: try JSONEncoder().encode(command), as: UTF8.self))
            await waitUntil("terminal writes the first command") { FileManager.default.fileExists(atPath: repo.path + "/stream.txt") }
            connection.close()
            let sessionName = TmuxSessions.sessionName(workspaceID: workspace.id, paneID: "https")
            let probe = try await Shell.run(tmux, ["-L", TmuxSessions.socketName(databasePath: store.path), "has-session", "-t", "=" + sessionName], cwd: repo.path)
            #expect(probe.ok)
            let second = await runtime.respond(to: ServerRequest(.terminalStream(workspaceID: workspace.id, name: "https")))
            guard case .text(let nextPath) = second.result else { Issue.record("Reconnect failed"); await runtime.shutdown(); return }
            let reconnected = try UnixSocketConnection.connect(to: nextPath)
            let next = ServerTerminalFrame(kind: "input", data: Data("printf 'second\\n' >> stream.txt\r".utf8))
            reconnected.writeLine(String(decoding: try JSONEncoder().encode(next), as: UTF8.self))
            await waitUntil("reconnected terminal executes once") {
                (try? String(contentsOfFile: repo.path + "/stream.txt", encoding: .utf8)) == "first\nsecond\n"
            }
            #expect(try String(contentsOfFile: repo.path + "/stream.txt", encoding: .utf8) == "first\nsecond\n")
            reconnected.close()
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}

private actor TerminalStartGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
