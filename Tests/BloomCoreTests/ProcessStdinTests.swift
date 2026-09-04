import Foundation
import Testing
@testable import BloomCore

/// The segmentation fault the quota reader took the app down with.
///
/// A dev build died on `EXC_BAD_ACCESS`, a byte read at address 0x64, inside
/// `_NSFileHandleIsClosed` reached from `StreamingProcess.write`. The stack under it was
/// `AgentQuotaSources.readAll` into `CodexQuotaSource.read` into `CodexClient.start`, so the
/// crashing write was the `initialize` line of the handshake, and a second thread was inside
/// `StreamingProcess.start()` for the Claude Code source at the same moment, doing the launch the
/// Codex source had not done. A field read off nothing, on the first write of a connection: the
/// handle was reached for in a state nobody had checked.
///
/// Two states are not writable and neither was asked about. The child has never been launched,
/// which is what `CodexClient` did every time, because it left claiming `lines` to an unstructured
/// task that cannot run until the actor is free and the actor is held right through the write. And
/// `closeStdin` is closing that same handle from another thread, which is what
/// `CodexRunner.terminateNow` does from the main actor on Stop, close, archive and quit, and which
/// the old check could not stop because it read its flag under the lock and then wrote outside it.
///
/// A quota reading is a background convenience. Nothing it does may take the app down, so the
/// tests here write to processes that are not there rather than reasoning about whether anything
/// would.
///
/// **The second way a dying child took Bloom down, found by this suite.** The first CI run of it
/// killed the whole test binary with signal 13, SIGPIPE, part way through and named no failing
/// test. Writing to a pipe nobody is reading raises that signal, its default disposition is to
/// kill the process, and nothing in this tree turns it off: `UnixSocketConnection` sets
/// `SO_NOSIGPIPE` on every socket it owns and says in as many words that without it an agent CLI
/// exiting mid-call would take Bloom down, and the pipe to a child had never been given the same
/// treatment. So the null handle and the signal were the same bug wearing two hats, and the guard
/// in `write` cannot cover the second one: `status` is only set once `settle` has waited out its
/// quiet period, leaving a window in which a child is dead and the bookkeeping says otherwise.
/// `StreamingProcess.init` and `Shell.run` set `F_SETNOSIGPIPE` on the descriptors they write a
/// child on, which turns that signal into the EPIPE the code already handled.
@Suite("Writing to a process that is not there")
struct ProcessStdinTests {

    // MARK: - StreamingProcess

    @Test("a line written before the child is launched is refused rather than queued", .timeLimit(.minutes(1)))
    func aWriteBeforeTheLaunchIsRefused() async throws {
        let process = StreamingProcess(executable: "/bin/cat", arguments: [])

        // Nothing has claimed `lines`, so nothing has launched `cat` and the pipe has no process
        // behind it. This used to be written into it anyway, and `cat` read it after exec.
        process.writeLine("before-the-launch")

        // Claiming the stream is what launches the child.
        let lines = process.lines
        process.writeLine("after-the-launch")
        process.closeStdin()

        var seen: [String] = []
        for try await line in lines { seen.append(line) }

        #expect(seen == ["after-the-launch"])
        #expect(await process.exitStatus == 0)
    }

    @Test("a process that has already exited is not written to", .timeLimit(.minutes(1)))
    func aWriteAfterTheExitIsRefused() async throws {
        let process = StreamingProcess(executable: "/bin/echo", arguments: ["done"])

        var seen: [String] = []
        for try await line in process.lines { seen.append(line) }
        #expect(seen == ["done"])
        #expect(await process.exitStatus == 0)

        // The child is gone and nobody called `closeStdin`, which is the only thing the old guard
        // asked about. Reaching the end of this is the assertion.
        for _ in 0..<200 { process.writeLine("into the void") }
    }

    @Test("a write to a pipe nobody is reading fails the write rather than the process", .timeLimit(.minutes(1)))
    func aPipeWithNoReaderFailsTheWriteRatherThanTheProcess() throws {
        // The option `StreamingProcess.init` puts on its stdin descriptor, asserted on a pipe
        // this test owns, so the question is the descriptor's behaviour rather than whether a
        // race with a dying child was won. Without the `fcntl` this does not throw, it ends the
        // program, which is how the first CI run of this suite died. Pinned here rather than left
        // implicit because the whole fix rests on the platform answering EPIPE.
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try pipe.fileHandleForReading.close()

        #expect(throws: (any Error).self) {
            try pipe.fileHandleForWriting.write(contentsOf: Data("nobody is reading".utf8))
        }
        try? pipe.fileHandleForWriting.close()
    }

    @Test("stdin closing under a write does not fault", .timeLimit(.minutes(2)))
    func aCloseDoesNotLandUnderAWrite() async throws {
        // The crash, as directly as it can be provoked from a test: writers on the cooperative
        // pool and a close from beside them, repeated, because the window is a handful of
        // instructions wide. `closeStdin` used to close the handle whatever a writer was doing
        // with it.
        //
        // This is also the test that found the SIGPIPE. `terminate` kills the child while writers
        // are still going, so some of those writes land on a pipe with no reader, and on CI that
        // ended the test binary rather than any test in it.
        for _ in 0..<40 {
            let process = StreamingProcess(executable: "/bin/cat", arguments: [])
            _ = process.lines

            await withTaskGroup(of: Void.self) { group in
                for index in 0..<16 {
                    group.addTask { process.writeLine("line-\(index)") }
                }
                group.addTask { process.closeStdin() }
                group.addTask { process.terminate() }
            }

            _ = await process.exitStatus
        }
    }

    // MARK: - CodexClient

    @Test("the Codex handshake goes to a process that has been launched", .timeLimit(.minutes(1)))
    func theHandshakeIsWrittenAfterTheLaunch() async throws {
        let process = LaunchOrderProcess()
        let client = CodexClient(
            configuration: CodexClient.Configuration(cwd: "/tmp"),
            makeProcess: { _ in process }
        )

        try await client.start()
        await client.stop()

        #expect(process.wroteBeforeTheLaunch == false)
        #expect(process.linesWereClaimed)
    }

    // MARK: - The quota sources

    @Test("a Codex source whose process says nothing answers nothing", .timeLimit(.minutes(1)))
    func aSilentCodexProcessFailsAsASource() async {
        let source = CodexQuotaSource(makeProcess: { _ in DeadProcess() })

        // A source that cannot talk to its process contributes nothing, which is the same
        // outcome as never having been asked, and is what `readAll` is written to expect.
        let payload = await source.read()
        #expect(payload == nil)

        let quotas = await AgentQuotaSources.readAll([source] as [any AgentQuotaSource])
        #expect(quotas.isEmpty)
    }
}

// MARK: - Doubles

/// Records whether anything claimed `lines`, which is what launches a real child, before the first
/// line was written to it.
private final class LaunchOrderProcess: AgentProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false
    private var firstWriteSawTheLaunch: Bool?

    private let stdout: AsyncThrowingStream<String, Error>
    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let stderr: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    init() {
        (stdout, stdoutContinuation) = AsyncThrowingStream.makeStream(
            of: String.self, throwing: Error.self, bufferingPolicy: .unbounded
        )
        (stderr, stderrContinuation) = AsyncStream.makeStream(
            of: String.self, bufferingPolicy: .unbounded
        )
    }

    /// False when nothing was written at all, which is a failure of a different shape and is
    /// caught by `linesWereClaimed` beside it.
    var wroteBeforeTheLaunch: Bool {
        lock.lock(); defer { lock.unlock() }
        return firstWriteSawTheLaunch == false
    }

    var linesWereClaimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return launched
    }

    var lines: AsyncThrowingStream<String, Error> {
        lock.lock(); launched = true; lock.unlock()
        return stdout
    }

    var errorLines: AsyncStream<String> { stderr }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return launched
    }

    var exitStatus: Int32 { get async { 0 } }

    func writeLine(_ text: String) {
        lock.lock()
        if firstWriteSawTheLaunch == nil { firstWriteSawTheLaunch = launched }
        lock.unlock()

        // Answer anything with an id, so the handshake completes and the test is about the order
        // rather than about a timeout.
        guard let json = JSONValue.parse(text), let id = json["id"] else { return }
        stdoutContinuation.yield("{\"id\":\(id.compactJSON),\"result\":{}}")
    }

    func closeStdin() {}

    func terminate() {
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }

    func kill() { terminate() }
}

/// A process that ended before anybody asked it anything.
private final class DeadProcess: AgentProcessing, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>

    init() {
        let (stdout, out) = AsyncThrowingStream.makeStream(
            of: String.self, throwing: Error.self, bufferingPolicy: .unbounded
        )
        let (stderr, err) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        lines = stdout
        errorLines = stderr
        out.finish()
        err.finish()
    }

    var isRunning: Bool { false }
    var exitStatus: Int32 { get async { 1 } }

    func writeLine(_ text: String) {}
    func closeStdin() {}
    func terminate() {}
    func kill() {}
}
