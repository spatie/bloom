import Foundation
import Synchronization

/// One worker owns the pipe descriptors, from opening to closing. Nonblocking I/O lets the same
/// deadline cover a blocked stdin writer, a stubborn child, and inherited output after exit.
/// Previously Shell stopped its timer at child exit and could return success minutes later.
final class CapturedProcess: Sendable {
    private let cancelled = Mutex(false)
    private let executable: String
    private let arguments: [String]
    private let cwd: String?
    private let environment: [String: String]
    private let input: Data?
    private let timeout: Duration?
    private let outputLimit: Int

    init(
        executable: String, arguments: [String], cwd: String?, environment: [String: String],
        input: Data?, timeout: Duration?, outputLimit: Int
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.input = input
        self.timeout = timeout
        self.outputLimit = max(1, outputLimit)
    }

    func run() async throws -> ShellBytes {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let worker = Thread { [self] in
                    do { continuation.resume(returning: try capture()) } catch { continuation.resume(throwing: error) }
                }
                worker.stackSize = 512 * 1_024
                worker.start()
            }
        } onCancel: {
            self.cancelled.withLock { $0 = true }
        }
    }

    private func capture() throws -> ShellBytes {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin

        // The worker is the only reader/writer. Closing in its defer cannot race a readability
        // callback or close a descriptor that another reader has already released and reused.
        let handles = [output.fileHandleForReading, errors.fileHandleForReading, stdin.fileHandleForWriting]
        defer {
            for handle in handles { try? handle.close() }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
        }
        for handle in handles {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw pipeFailure("configure pipes", errno)
            }
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let started = ContinuousClock.now
        let deadline = timeout.map { started.advanced(by: $0) }
        try process.run()
        Shell.countSpawn()
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid && pid != getpgrp()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()

        do {
            return try collect(
                process: process, handles: handles, deadline: deadline
            )
        } catch {
            // Only this invocation's process/group is signalled. Never kill Bloom's own group
            // when a platform or launcher has kept the child in it.
            stop(process, pid: pid, ownsGroup: ownsGroup)
            throw error
        }
    }

    private func collect(
        process: Process, handles: [FileHandle], deadline: ContinuousClock.Instant?
    ) throws -> ShellBytes {
        var streams = [Data(), Data()]
        var readers = [true, true]
        var inputOffset = 0
        var inputOpen = true
        var exitedAt: ContinuousClock.Instant?
        let bytes = input ?? Data()
        while true {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let now = ContinuousClock.now
            if let deadline, now >= deadline { throw ShellFailure.timedOut(command: executable) }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                if !readers.contains(true) {
                    return ShellBytes(status: process.terminationStatus, stdout: streams[0], stderr: streams[1])
                }
                // Even calls with no execution deadline cannot wait forever on a grandchild.
                if let exitedAt, exitedAt.duration(to: now) >= .seconds(2) {
                    throw ShellFailure.incompleteOutput(command: executable)
                }
            }
            if inputOpen && inputOffset == bytes.count {
                try? handles[2].close()
                inputOpen = false
            }
            var descriptors = handles.enumerated().map { index, handle in
                let active = index < 2 ? readers[index] : inputOpen
                return pollfd(
                    fd: active ? handle.fileDescriptor : -1,
                    events: Int16(index < 2 ? POLLIN : POLLOUT), revents: 0
                )
            }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
            if ready < 0 {
                if errno == EINTR { continue }
                throw pipeFailure("wait for output", errno)
            }
            for index in 0..<2 where readers[index] && descriptors[index].revents != 0 {
                let chunk = try readChunk(descriptors[index].fd)
                if let chunk {
                    if chunk.isEmpty { readers[index] = false } else {
                        guard chunk.count <= outputLimit - streams[index].count else {
                            throw ShellFailure.outputLimit(
                                command: executable, stream: index == 0 ? "stdout" : "stderr", limit: outputLimit
                            )
                        }
                        streams[index].append(chunk)
                    }
                }
            }
            if inputOpen && descriptors[2].revents != 0 {
                let count = bytes.withUnsafeBytes { buffer in
                    write(descriptors[2].fd, buffer.baseAddress!.advanced(by: inputOffset), min(65_536, bytes.count - inputOffset))
                }
                if count > 0 { inputOffset += count } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    // A child may legitimately reject input with its own useful exit status.
                    // EPIPE closes stdin while stdout/stderr continue to drain that explanation.
                    if errno != EPIPE { throw pipeFailure("write input", errno) }
                    try? handles[2].close()
                    inputOpen = false
                }
            }
        }
    }

    private func readChunk(_ descriptor: Int32) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &buffer, buffer.count)
        if count >= 0 { return Data(buffer.prefix(count)) }
        if errno == EAGAIN || errno == EINTR { return nil }
        throw pipeFailure("read output", errno)
    }

    private func pipeFailure(_ operation: String, _ code: Int32) -> ShellFailure {
        .pipe(command: executable, operation: operation, code: code)
    }

    private func stop(_ process: Process, pid: Int32, ownsGroup: Bool) {
        if ownsGroup { _ = killpg(pid, SIGTERM) } else if process.isRunning { _ = kill(pid, SIGTERM) }
        let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
        while process.isRunning && ContinuousClock.now < grace { Thread.sleep(forTimeInterval: 0.01) }
        if ownsGroup { _ = killpg(pid, SIGKILL) } else if process.isRunning { _ = kill(pid, SIGKILL) }
        // Reap only the child we created. SIGKILL cannot be ignored by a userspace process.
        process.waitUntilExit()
    }
}
