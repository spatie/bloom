import Foundation
import Synchronization

/// A long-lived subprocess whose output is consumed line by line while it runs, and whose stdin
/// stays open so more input can be written later. This is what both setup scripts and the agent
/// run on.
public final class StreamingProcess: Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    /// Everything that moves after launch, in one value: what each pipe has delivered and
    /// whether it has hit end of file, whether the child has started and exited, and who is
    /// waiting on the exit status. One `Mutex` rather than one per concern because `settle` and
    /// `finish` decide from several of these at once, and a decision assembled from separate
    /// locks would describe no moment at all. `Mutex<State>` rather than `NSLock` plus
    /// `@unchecked Sendable`, for the reason given on `EventFanout` in `SessionRunner`.
    private struct State {
        var stdoutBuffer = Data()
        var stderrBuffer = Data()
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
        var status: Int32?
        var stdinClosed = false
        var started = false
        /// Whether each pipe has reported end of file, which is the only trustworthy signal that
        /// the child is done writing to it.
        var stdoutAtEOF = false
        var stderrAtEOF = false
        /// When the last byte arrived on either pipe, used to tell "still flushing" from
        /// "finished".
        var lastOutputAt = DispatchTime.now()
        /// When the child exited, recorded the first time `settle` runs for that exit.
        var exitedAt: DispatchTime?
    }

    private let state = Mutex(State())

    /// Every extract-and-yield runs here, one at a time, and so does `finish`.
    ///
    /// The drains used to take a batch out of the buffer under the `Mutex` and yield it outside,
    /// with two callers reaching them at once: the pipe's readability handler, and `settle`
    /// re-entering from its own timer. Batch N+1 could then be yielded before batch N. The buffer
    /// was protected; the ordering the buffer exists to preserve was not, and `AgentRunner.ingest`
    /// writes one transcript row per line, so an inversion can land a turn's `result` before the
    /// assistant events it closes. Serialising the yields is what makes the stream ordered, and
    /// putting `finish` on the same queue is what stops the stream ending before the lines it owes.
    private let drainQueue = DispatchQueue(label: "be.spatie.bloom.StreamingProcess.drain")

    /// Both streams are built here rather than in a `lazy var`.
    ///
    /// A `lazy var` on a class carries no synchronisation, so two threads reaching `lines` at the
    /// same time can each build a stream and store its continuation over the other's. One of the
    /// two consumers then waits forever on a stream nothing yields into. Building them up front
    /// also means the continuations exist before the fork, so no output can arrive with nowhere
    /// to put it, and `start()` failing before anyone touched `lines` still finishes the stream.
    private let linesStream: AsyncThrowingStream<String, Error>
    private let linesContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let errorStream: AsyncStream<String>
    private let errorContinuation: AsyncStream<String>.Continuation

    public let mergeStderr: Bool

    private let executable: String
    private let arguments: [String]
    private let cwd: String?
    private let environment: [String: String]

    /// How long after the child exits the pipes may stay silent before the streams are closed
    /// anyway. A grandchild that inherited stdout holds the pipe open after its parent is gone,
    /// so waiting for a real EOF alone could wait forever.
    private static let eofQuietPeriod = DispatchTimeInterval.milliseconds(200)
    /// The hard stop, for a grandchild that not only holds the pipe but keeps writing to it.
    private static let eofHardLimit = DispatchTimeInterval.seconds(5)
    private static let eofPollInterval = DispatchTimeInterval.milliseconds(20)

    public init(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String] = Shell.environment(),
        mergeStderr: Bool = true
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.mergeStderr = mergeStderr

        (linesStream, linesContinuation) = AsyncThrowingStream.makeStream(
            of: String.self, throwing: Error.self, bufferingPolicy: .unbounded
        )
        // stdout is unbounded because every line of it is a transcript event that must not be
        // dropped. stderr is diagnostics, and the only thing ever read back from it is the tail,
        // so a bound stops a process that spews warnings from growing a buffer nobody drains.
        (errorStream, errorContinuation) = AsyncStream.makeStream(
            of: String.self, bufferingPolicy: .bufferingNewest(4_096)
        )

        linesContinuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.terminate() }
        }
    }

    public var isRunning: Bool {
        state.withLock { $0.started && $0.status == nil }
    }

    public var processIdentifier: Int32 {
        process.isRunning ? process.processIdentifier : -1
    }

    // MARK: - Streams

    /// Lines from stdout, and from stderr too when `mergeStderr` is set. Starts the process on
    /// first use. Only one consumer is supported.
    public var lines: AsyncThrowingStream<String, Error> {
        // A launch failure reaches the caller through the stream rather than as a thrown error,
        // because a property cannot throw and every consumer is already handling stream failure.
        try? start()
        return linesStream
    }

    /// Separate stderr stream, used when `mergeStderr` is false. Never throws: a failing process
    /// surfaces through `lines` and `exitStatus`.
    public var errorLines: AsyncStream<String> { errorStream }

    // MARK: - Lifecycle

    public func start() throws {
        let claimed = state.withLock { state -> Bool in
            if state.started { return false }
            state.started = true
            return true
        }
        guard claimed else { return }

        guard let path = Shell.which(executable) else {
            let error = ShellError(command: executable, status: 127, stderr: "\(executable) not found on PATH")
            finish(status: 127, error: error)
            throw error
        }

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.drainStdout(final: true)
                self.markEOF(stdout: true)
            } else {
                self.state.withLock { state in
                    state.stdoutBuffer.append(data)
                    state.lastOutputAt = DispatchTime.now()
                }
                self.drainStdout(final: false)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.drainStderr(final: true)
                self.markEOF(stdout: false)
            } else {
                self.state.withLock { state in
                    state.stderrBuffer.append(data)
                    state.lastOutputAt = DispatchTime.now()
                }
                self.drainStderr(final: false)
            }
        }

        process.terminationHandler = { [weak self] process in
            self?.settle(status: process.terminationStatus, deadline: nil)
        }

        do {
            try process.run()
        } catch {
            finish(status: -1, error: error)
            throw error
        }
    }

    public func write(_ text: String) {
        guard !state.withLock(\.stdinClosed) else { return }

        let handle = stdinPipe.fileHandleForWriting
        let data = Data(text.utf8)
        // A dead child turns a write into SIGPIPE, which `write(_:)` turns into an exception.
        do {
            try handle.write(contentsOf: data)
        } catch {
            // The process went away. Nothing useful to do beyond stopping further writes.
            state.withLock { $0.stdinClosed = true }
        }
    }

    public func writeLine(_ text: String) {
        write(text + "\n")
    }

    public func closeStdin() {
        let claimed = state.withLock { state -> Bool in
            if state.stdinClosed { return false }
            state.stdinClosed = true
            return true
        }
        guard claimed else { return }
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        signalGroup(SIGTERM)
        closeStdin()
    }

    /// SIGKILL, for a process that ignored SIGTERM.
    public func kill() {
        signalGroup(SIGKILL)
    }

    /// Signal the whole process group, not just the child.
    ///
    /// Foundation launches the child in a process group of its own, so every grandchild it forks
    /// lands in that same group. Signalling the pid alone kills `claude` and leaves the test run
    /// or the dev server it started holding a port, reparented to launchd. `killpg` reaches the
    /// lot of them.
    ///
    /// The guards matter more than the signal: group 0 means "my own group", and so does our own
    /// pgid, so either one would have Bloom signal itself. Both fall back to the single pid.
    private func signalGroup(_ signal: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        let group = getpgid(pid)
        if group > 0, group != getpgrp(), killpg(group, signal) == 0 { return }

        Foundation.kill(pid, signal)
    }

    public var exitStatus: Int32 {
        get async {
            await withCheckedContinuation { continuation in
                register(continuation)
            }
        }
    }

    /// Resumes immediately if the process already exited, otherwise queues the waiter.
    /// Synchronous on purpose: a lock may not be held across an await, and the continuation is
    /// resumed after it is released because resuming runs arbitrary code.
    private func register(_ continuation: CheckedContinuation<Int32, Never>) {
        let ready = state.withLock { state -> Int32? in
            guard let status = state.status else {
                state.exitWaiters.append(continuation)
                return nil
            }
            return status
        }
        if let ready { continuation.resume(returning: ready) }
    }

    // MARK: - Settling

    private func markEOF(stdout: Bool) {
        state.withLock { state in
            if stdout { state.stdoutAtEOF = true } else { state.stderrAtEOF = true }
        }
    }

    /// Close the streams once the child's output is genuinely complete.
    ///
    /// The child exiting says nothing about the pipes: whatever the readability handlers have not
    /// delivered yet is still in flight, and closing the streams on a fixed delay (it used to be
    /// 50ms) throws away the tail of a chatty process on a loaded machine. That is the same class
    /// of bug that made `git diff` come back empty, and here it would silently truncate a setup
    /// log or drop the agent's final `result` line.
    ///
    /// So the wait is for EOF on both pipes, which is the only signal that means "no more bytes".
    /// EOF can never arrive at all when a grandchild inherited stdout and outlived its parent, so
    /// two backstops bound it: a quiet period during which nothing new arrived, and a hard limit
    /// for the grandchild that also keeps writing.
    private func settle(status: Int32, deadline: DispatchTime?) {
        let limit = deadline ?? DispatchTime.now() + Self.eofHardLimit
        let now = DispatchTime.now()

        let (sawEOF, since, stdoutLive, stderrLive) = state.withLock { state -> (Bool, DispatchTime, Bool, Bool) in
            let exited = state.exitedAt ?? now
            state.exitedAt = exited
            // Counted from the exit as well as from the last byte, so a process that fell silent
            // before exiting still gets the full quiet period for its buffered output to land.
            return (
                state.stdoutAtEOF && state.stderrAtEOF,
                max(state.lastOutputAt, exited),
                !state.stdoutAtEOF,
                !state.stderrAtEOF
            )
        }

        let pending = (stdoutLive && Self.hasPendingBytes(stdoutPipe.fileHandleForReading))
            || (stderrLive && Self.hasPendingBytes(stderrPipe.fileHandleForReading))
        let quiet = now > since + Self.eofQuietPeriod && !pending
        guard sawEOF || quiet || now > limit else {
            DispatchQueue.global().asyncAfter(deadline: now + Self.eofPollInterval) { [weak self] in
                self?.settle(status: status, deadline: limit)
            }
            return
        }

        drainQueue.async { [self] in
            // Handlers off before the last drain, not after it. `finish` nils them too, but by
            // then the final drain has already run, which left a handler free to append bytes
            // between the drain and the close that nothing would ever yield.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            drainStdoutNow(final: true)
            drainStderrNow(final: true)
            finish(status: status, error: nil)
        }
    }

    /// Whether the kernel is still holding bytes this pipe's reader has not taken.
    ///
    /// The quiet period is counted from the last byte a readability handler delivered, so a
    /// handler the machine has not scheduled for 200ms reads as silence and `settle` closed the
    /// stream over output that was in the pipe the whole time. `poll` answers the question the
    /// handler cannot, and answers it without reading: the handler stays the only reader, so no
    /// two readers can take alternate halves of a line.
    ///
    /// Only asked of a pipe that has not reported end of file, because a closed and empty pipe
    /// reports itself readable and a `read` of it returns nothing. The grandchild case this
    /// backstop exists for is the opposite: the pipe is open, nobody is writing, and `poll`
    /// correctly says there is nothing there, so the quiet period still closes it in 200ms.
    private static func hasPendingBytes(_ handle: FileHandle) -> Bool {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        return descriptor.revents & Int16(POLLIN) != 0
    }

    // MARK: - Draining

    private func drainStdout(final: Bool) {
        drainQueue.async { [self] in drainStdoutNow(final: final) }
    }

    private func drainStderr(final: Bool) {
        drainQueue.async { [self] in drainStderrNow(final: final) }
    }

    /// Both halves of a drain, extraction and yield, on `drainQueue` and nowhere else.
    private func drainStdoutNow(final: Bool) {
        let extracted = state.withLock {
            Self.extractLines(from: &$0.stdoutBuffer, flushRemainder: final)
        }
        for line in extracted { linesContinuation.yield(line) }
    }

    private func drainStderrNow(final: Bool) {
        let extracted = state.withLock {
            Self.extractLines(from: &$0.stderrBuffer, flushRemainder: final)
        }
        for line in extracted {
            if mergeStderr {
                linesContinuation.yield(line)
            } else {
                errorContinuation.yield(line)
            }
        }
    }

    private static func extractLines(from buffer: inout Data, flushRemainder: Bool) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
        }
        if flushRemainder, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        return lines
    }

    private func finish(status: Int32, error: Error?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>]? in
            guard state.status == nil else { return nil }
            state.status = status
            let waiters = state.exitWaiters
            state.exitWaiters = []
            return waiters
        }
        guard let waiters else { return }

        // Nothing will be read from these again, and a live dispatch source on a pipe nobody
        // drains is a slow leak for the rest of the launch.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        linesContinuation.finish(throwing: error)
        errorContinuation.finish()
        for waiter in waiters { waiter.resume(returning: status) }
    }
}
