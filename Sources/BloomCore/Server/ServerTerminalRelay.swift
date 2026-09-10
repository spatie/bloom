import Foundation
import BloomClient
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// An SSH forced command can attach an already authorised terminal without gaining arbitrary exec
/// or Unix-socket forwarding. The owning daemon and its tmux sessions are unchanged.
enum ServerTerminalRelay {
    static func run(directory: String) async throws {
        let initial: Data = try await onQueue { try firstMessage() }
        guard !initial.isEmpty else { return }
        let line = initial.prefix { $0 != 10 }
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        guard object?["terminalSocket"] != nil || object?["terminalProtocol"] != nil else {
            let connection = try UnixSocketConnection.connect(to: ServerDaemon.socketPath(directory: directory))
            await ServerCommandLine.relay(connection, initial: initial)
            return
        }
        do {
            guard line.count <= 4_096, object?.count == 2, let handshake = try? JSONDecoder().decode(TerminalRelayHandshake.self, from: line),
                  handshake.terminalProtocol == 1 else { throw ServerFailure("Unsupported terminal relay handshake.") }
            try validateSocket(handshake.terminalSocket)
            let pending = Data(initial.dropFirst(line.count + 1))
            try await onQueue { try pump(path: handshake.terminalSocket, initial: pending) }
        } catch {
            let reply = try JSONSerialization.data(withJSONObject: ["terminalError": error.localizedDescription])
            try? FileHandle.standardOutput.write(contentsOf: reply + Data([10]))
        }
    }

    static func validateSocket(_ path: String) throws {
        guard TerminalRelayHandshake.isAllowedPath(path) else { throw ServerFailure("Invalid Bloom terminal stream address.") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK), info.st_uid == getuid() else {
            throw ServerFailure("The terminal stream expired or belongs to another account. Reopen the terminal.")
        }
    }

    private static func onQueue<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "be.spatie.bloom.terminal-relay").async {
                do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func firstMessage() throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while data.count <= 16_777_216 {
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return Data() }
            if count < 0 {
                if errno == EINTR { continue }
                throw ServerFailure("Could not read the SSH request.")
            }
            data.append(contentsOf: bytes.prefix(count))
            if data.contains(10) { return data }
        }
        throw ServerFailure("The SSH request exceeded 16 MB.")
    }

    private static func validateFrames(_ bytes: Data, partialBytes: inout Int) throws {
        for byte in bytes {
            if byte == 10 { partialBytes = 0 } else { partialBytes += 1 }
            guard partialBytes <= 100_000 else { throw ServerFailure("The terminal input frame exceeded its limit.") }
        }
    }

    /// One bounded buffer in each direction. Polling writable descriptors avoids blocking output
    /// from starving input, and pausing reads propagates terminal backpressure through SSH.
    private static func pump(path: String, initial: Data) throws {
        var address = try UnixSocketAddress.make(path: path)
        let descriptor = socket(AF_UNIX, SystemCalls.streamSocketType, 0)
        guard descriptor >= 0 else { throw ServerFailure("Could not open the terminal stream.") }
        defer { SystemCalls.close(descriptor) }
        let result = UnixSocketAddress.withSocketAddress(&address) { pointer, length in
            SystemCalls.connect(descriptor, pointer, length)
        }
        guard result == 0 else { throw ServerFailure("The terminal stream expired. Reopen the terminal.") }
        #if canImport(Darwin)
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let descriptors = [STDIN_FILENO, STDOUT_FILENO, descriptor]
        let flags = descriptors.map { fcntl($0, F_GETFL, 0) }
        for (index, value) in descriptors.enumerated() { _ = fcntl(value, F_SETFL, flags[index] | O_NONBLOCK) }
        defer { for (index, value) in descriptors.enumerated() { _ = fcntl(value, F_SETFL, flags[index]) } }
        var input = initial
        var inputLineBytes = 0
        try validateFrames(initial, partialBytes: &inputLineBytes)
        var output = Data("{\"terminalReady\":true}\n".utf8)
        var socketEnded = false
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while !socketEnded || !output.isEmpty {
            var waits = [
                pollfd(fd: STDIN_FILENO, events: input.count < 65_536 && !socketEnded ? Int16(POLLIN) : 0, revents: 0),
                pollfd(fd: STDOUT_FILENO, events: output.isEmpty ? 0 : Int16(POLLOUT), revents: 0),
                pollfd(fd: descriptor, events: (output.count < 65_536 && !socketEnded ? Int16(POLLIN) : 0) | (input.isEmpty ? 0 : Int16(POLLOUT)), revents: 0)
            ]
            let count = poll(&waits, nfds_t(waits.count), 1_000)
            if count < 0 { if errno == EINTR { continue }; return }
            if waits[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let received = read(STDIN_FILENO, &bytes, bytes.count)
                if received == 0 { return }
                if received > 0 {
                    let data = Data(bytes.prefix(received))
                    try validateFrames(data, partialBytes: &inputLineBytes)
                    input.append(data)
                }
            }
            if waits[2].revents & Int16(POLLOUT) != 0, !input.isEmpty {
                let sent = input.withUnsafeBytes { SystemCalls.socketWrite(descriptor, $0.baseAddress, $0.count) }
                if sent > 0 { input.removeFirst(sent) } else if errno != EAGAIN && errno != EINTR { return }
            }
            if waits[2].revents & Int16(POLLIN | POLLHUP) != 0, !socketEnded {
                let received = read(descriptor, &bytes, bytes.count)
                if received == 0 { socketEnded = true; input.removeAll() }
                if received > 0 { output.append(contentsOf: bytes.prefix(received)) }
            }
            if waits[1].revents & Int16(POLLOUT) != 0, !output.isEmpty {
                let sent = output.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
                if sent > 0 { output.removeFirst(sent) } else if errno != EAGAIN && errno != EINTR { return }
            }
            if waits.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) { return }
        }
    }
}
