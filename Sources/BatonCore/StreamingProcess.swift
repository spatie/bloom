import Foundation

/// A long-lived subprocess whose output is consumed line by line while it runs, and whose stdin
/// stays open so more input can be written later. This is what both setup scripts and the agent
/// run on.
public final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var status: Int32?
    private var launchError: Error?
    private var stdinClosed = false
    private var started = false
    /// Whether each pipe has reported end of file, which is the only trustworthy signal that the
    /// child is done writing to it.
    private var stdoutAtEOF = false
    private var stderrAtEOF = false
    /// When the last byte arrived on either pipe, used to tell "still flushing" from "finished".
    private var lastOutputAt = DispatchTime.now()
    /// When the child exited, recorded the first time `settle` runs for that exit.
    private var exitedAt: DispatchTime?

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
        lock.lock(); defer { lock.unlock() }
        return started && status == nil
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
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

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
                self.lock.lock()
                self.stdoutBuffer.append(data)
                self.lastOutputAt = DispatchTime.now()
                self.lock.unlock()
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
                self.lock.lock()
                self.stderrBuffer.append(data)
                self.lastOutputAt = DispatchTime.now()
                self.lock.unlock()
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
        lock.lock()
        let closed = stdinClosed
        lock.unlock()
        guard !closed else { return }

        let handle = stdinPipe.fileHandleForWriting
        let data = Data(text.utf8)
        // A dead child turns a write into SIGPIPE, which `write(_:)` turns into an exception.
        do {
            try handle.write(contentsOf: data)
        } catch {
            // The process went away. Nothing useful to do beyond stopping further writes.
            lock.lock(); stdinClosed = true; lock.unlock()
        }
    }

    public func writeLine(_ text: String) {
        write(text + "\n")
    }

    public func closeStdin() {
        lock.lock()
        guard !stdinClosed else { lock.unlock(); return }
        stdinClosed = true
        lock.unlock()
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
    /// pgid, so either one would have Baton signal itself. Both fall back to the single pid.
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
    /// Synchronous on purpose: NSLock may not be held across an await.
    private func register(_ continuation: CheckedContinuation<Int32, Never>) {
        lock.lock()
        if let status {
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            exitWaiters.append(continuation)
            lock.unlock()
        }
    }

    // MARK: - Settling

    private func markEOF(stdout: Bool) {
        lock.lock()
        if stdout { stdoutAtEOF = true } else { stderrAtEOF = true }
        lock.unlock()
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

        lock.lock()
        let sawEOF = stdoutAtEOF && stderrAtEOF
        let exited = exitedAt ?? now
        exitedAt = exited
        // Counted from the exit as well as from the last byte, so a process that fell silent
        // before exiting still gets the full quiet period for its buffered output to land.
        let since = max(lastOutputAt, exited)
        lock.unlock()

        let quiet = now > since + Self.eofQuietPeriod
        guard sawEOF || quiet || now > limit else {
            DispatchQueue.global().asyncAfter(deadline: now + Self.eofPollInterval) { [weak self] in
                self?.settle(status: status, deadline: limit)
            }
            return
        }

        drainStdout(final: true)
        drainStderr(final: true)
        finish(status: status, error: nil)
    }

    // MARK: - Draining

    private func drainStdout(final: Bool) {
        lock.lock()
        let extracted = Self.extractLines(from: &stdoutBuffer, flushRemainder: final)
        lock.unlock()

        for line in extracted { linesContinuation.yield(line) }
    }

    private func drainStderr(final: Bool) {
        lock.lock()
        let extracted = Self.extractLines(from: &stderrBuffer, flushRemainder: final)
        lock.unlock()

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
        lock.lock()
        guard self.status == nil else { lock.unlock(); return }
        self.status = status
        launchError = error
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()

        // Nothing will be read from these again, and a live dispatch source on a pipe nobody
        // drains is a slow leak for the rest of the launch.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        linesContinuation.finish(throwing: error)
        errorContinuation.finish()
        for waiter in waiters { waiter.resume(returning: status) }
    }
}
