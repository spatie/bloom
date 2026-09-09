import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import BloomCore

@Suite("ServerTerminalStream", .scratchDirectory, .tags(.subprocess, .persistence))
struct ServerTerminalStreamTests {
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
        let runtime = ServerRuntime(store: store)
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
