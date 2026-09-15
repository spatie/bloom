import Foundation
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Private bounded capture: no logging, progress callbacks, inherited credential variables or stderr.
enum ServerCredentialImportProcess {
    struct Result: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let status: Int32
        let output: Data
        var description: String { "Private credential command result" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    private final class Cancellation: Sendable { let value = Mutex(false) }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String], input: Data = Data(),
                    limit: Int = 32768, timeout: TimeInterval = 25, workingDirectory: String? = nil,
                    captureStderr: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let cancelled = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execute(executable, arguments, environment: environment, input: input, limit: limit, timeout: timeout, cancelled: cancelled, workingDirectory: workingDirectory, captureStderr: captureStderr)) } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancelled.value.withLock { $0 = true } }
    }

    private static func execute(_ executable: String, _ arguments: [String], environment: [String: String], input: Data,
                                limit: Int, timeout: TimeInterval, cancelled: Cancellation, workingDirectory: String?, captureStderr: Bool) throws -> Result {
        guard !cancelled.value.withLock({ $0 }) else { throw CancellationError() }
        var incoming: [Int32] = [0, 0]
        var outgoing: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SystemCalls.streamSocketType, 0, &incoming) == 0 else { throw unavailable() }
        defer { SystemCalls.close(incoming[0]); SystemCalls.close(incoming[1]) }
        guard pipe(&outgoing) == 0 else { throw unavailable() }
        defer { SystemCalls.close(outgoing[0]); SystemCalls.close(outgoing[1]) }
        let sink = open("/dev/null", O_WRONLY)
        guard sink >= 0 else { throw unavailable() }
        defer { SystemCalls.close(sink) }
        for descriptor in incoming + outgoing + [sink] {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw unavailable() }
        }
        for descriptor in [incoming[0], outgoing[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw unavailable() }
        }
        #if canImport(Darwin)
        var yes: Int32 = 1
        guard setsockopt(incoming[0], SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw unavailable() }
        #endif
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw unavailable() }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw unavailable() }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, incoming[1], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, captureStderr ? outgoing[1] : sink, STDERR_FILENO) == 0 else { throw unavailable() }
        if let workingDirectory {
            #if os(Linux)
            guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) == 0 else { throw unavailable() }
            #else
            guard posix_spawn_file_actions_addchdir(&actions, workingDirectory) == 0 else { throw unavailable() }
            #endif
        }
        var signals = sigset_t(); sigemptyset(&signals)
        guard posix_spawnattr_setsigmask(&attributes, &signals) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK)) == 0 else { throw unavailable() }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + env { free(value) } }
        var pid: pid_t = 0
        let launched = posix_spawn(&pid, executable, &actions, &attributes, &argv, &env)
        guard launched == 0 else { throw unavailable() }
        Shell.countSpawn()
        var reaped = false
        defer {
            _ = kill(-pid, SIGKILL)
            if !reaped { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        // Socket stdin prevents SIGPIPE from terminating Bloom when SSH refuses before reading.
        SystemCalls.close(incoming[1]); incoming[1] = -1
        SystemCalls.close(outgoing[1]); outgoing[1] = -1
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var sent = 0, result = Data(), eof = false, finishedInput = false
        var status: Int32 = 0
        while true {
            if cancelled.value.withLock({ $0 }) { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ServerCredentialImport.Failure(message: "Credential transfer timed out.", recovery: "The server may have received the credential. Check its accounts before retrying.")
            }
            if !finishedInput {
                if sent == input.count { _ = shutdown(incoming[0], Int32(SHUT_WR)); finishedInput = true } else {
                    let count = input.withUnsafeBytes { bytes in
                        #if os(Linux)
                        send(incoming[0], bytes.baseAddress?.advanced(by: sent), min(16384, input.count - sent), Int32(MSG_NOSIGNAL))
                        #else
                        send(incoming[0], bytes.baseAddress?.advanced(by: sent), min(16384, input.count - sent), 0)
                        #endif
                    }
                    if count > 0 { sent += count } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { finishedInput = true }
                }
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(outgoing[0], &bytes, bytes.count)
            if count > 0 {
                guard result.count + count <= limit else { throw unavailable() }
                result.append(contentsOf: bytes.prefix(count))
            } else if count == 0 { eof = true }
            if !reaped { reaped = waitpid(pid, &status, WNOHANG) == pid }
            if reaped && eof { return Result(status: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f), output: result) }
            var events = pollfd(fd: eof ? -1 : outgoing[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&events, 1, 20)
        }
    }

    private static func unavailable() -> ServerCredentialImport.Failure {
        ServerCredentialImport.failure("The private credential command could not complete.")
    }
}
