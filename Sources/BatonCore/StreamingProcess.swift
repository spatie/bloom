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
    private var stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var stderrContinuation: AsyncStream<String>.Continuation?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var status: Int32?
    private var launchError: Error?
    private var stdinClosed = false
    private var started = false

    public let mergeStderr: Bool

    private let executable: String
    private let arguments: [String]
    private let cwd: String?
    private let environment: [String: String]

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
    public lazy var lines: AsyncThrowingStream<String, Error> = {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            stdoutContinuation = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.terminate() }
            }

            do {
                try start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }()

    /// Separate stderr stream, used when `mergeStderr` is false. Never throws: a failing process
    /// surfaces through `lines` and `exitStatus`.
    public lazy var errorLines: AsyncStream<String> = {
        AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            stderrContinuation = continuation
            lock.unlock()
        }
    }()

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
            } else {
                self.lock.lock()
                self.stdoutBuffer.append(data)
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
            } else {
                self.lock.lock()
                self.stderrBuffer.append(data)
                self.lock.unlock()
                self.drainStderr(final: false)
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // Give the readability handlers a moment to flush what is already buffered.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                self.drainStdout(final: true)
                self.drainStderr(final: true)
                self.finish(status: process.terminationStatus, error: nil)
            }
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
        if process.isRunning {
            process.terminate()
        }
        closeStdin()
    }

    /// SIGKILL, for a process that ignored SIGTERM.
    public func kill() {
        if process.isRunning {
            Foundation.kill(process.processIdentifier, SIGKILL)
        }
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

    // MARK: - Draining

    private func drainStdout(final: Bool) {
        lock.lock()
        let extracted = Self.extractLines(from: &stdoutBuffer, flushRemainder: final)
        let continuation = stdoutContinuation
        lock.unlock()

        for line in extracted { continuation?.yield(line) }
    }

    private func drainStderr(final: Bool) {
        lock.lock()
        let extracted = Self.extractLines(from: &stderrBuffer, flushRemainder: final)
        let stdout = stdoutContinuation
        let stderr = stderrContinuation
        lock.unlock()

        for line in extracted {
            if mergeStderr {
                stdout?.yield(line)
            } else {
                stderr?.yield(line)
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
        let stdout = stdoutContinuation
        let stderr = stderrContinuation
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()

        stdout?.finish(throwing: error)
        stderr?.finish()
        for waiter in waiters { waiter.resume(returning: status) }
    }
}
