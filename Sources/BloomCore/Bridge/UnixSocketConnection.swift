import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Synchronization

/// One end of a connected unix domain socket, read as lines and written as lines.
///
/// Line delimited JSON both ways, because that is what MCP over stdio already is and the shim is a
/// relay: whatever the CLI wrote on one line arrives here as one line and goes back the same way.
///
/// Darwin sockets use `SO_NOSIGPIPE`; Linux writes use `MSG_NOSIGNAL`. A disconnected client
/// must cause a failed write, never a SIGPIPE that takes down every other server session.
public final class UnixSocketConnection: Sendable {
    private let descriptor: Int32
    private let source = Mutex<(any DispatchSourceRead)?>(nil)
    private let buffer = LineBuffer()
    /// Whether the descriptor has been given back to the kernel. Guarded by a `Mutex` rather
    /// than `NSLock` plus `@unchecked Sendable`, for the reason given on `EventFanout` in
    /// `SessionRunner`, and every write happens under this same lock on purpose: `close` can only
    /// mark the flag once no write is mid-flight, so the descriptor can never be reclaimed
    /// underneath a writer.
    private let closed = Mutex(false)
    private let writer = Mutex(())
    private let writeQueue = DispatchQueue(label: "be.spatie.bloom.bridge.write", qos: .utility)
    private let writeTimeout: Duration

    /// Lines from the far end, ending when it closes. Unbounded, because every line is a request
    /// or a reply and dropping one strands whoever is waiting for it.
    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(descriptor: Int32, writeTimeout: Duration = .seconds(30)) {
        self.descriptor = descriptor
        self.writeTimeout = writeTimeout
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)

        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Darwin Unix-domain send can still block with MSG_DONTWAIT alone. Keep the
        // descriptor nonblocking too, so a slow peer cannot hold the close lock.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        source.withLock {
            let reader = DispatchSource.makeReadSource(
                fileDescriptor: descriptor, queue: DispatchQueue(label: "be.spatie.bloom.bridge.read")
            )
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            // FileHandle's readability handler cancels asynchronously. Closing its descriptor
            // ourselves let Linux recycle it while libdispatch still watched it, crashing the
            // event loop under connection churn. Only the cancellation handler may release it.
            reader.setCancelHandler { SystemCalls.close(descriptor) }
            reader.resume()
            $0 = reader
        }
    }

    /// Connects to a listening socket, or says why it could not.
    ///
    /// No retry and no wait. The ordinary reason this fails is that Bloom has quit and somebody is
    /// running the CLI by hand, and the right answer to that is one sentence immediately rather
    /// than a tool call that hangs for a timeout the model cannot see.
    public static func connect(to path: String) throws -> UnixSocketConnection {
        var address = try UnixSocketAddress.make(path: path)
        let descriptor = socket(AF_UNIX, SystemCalls.streamSocketType, 0)
        guard descriptor >= 0 else { throw UnixSocketError.couldNotOpen(code: errno) }

        let result = UnixSocketAddress.withSocketAddress(&address) { socketAddress, length in
            SystemCalls.connect(descriptor, socketAddress, length)
        }
        guard result == 0 else {
            let code = errno
            SystemCalls.close(descriptor)
            throw UnixSocketError.couldNotConnect(path: path, code: code)
        }
        return UnixSocketConnection(descriptor: descriptor)
    }

    private func deliver(_ data: Data) {
        for line in buffer.take(data) { continuation.yield(line) }
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while !closed.withLock({ $0 }) {
            let count = bytes.withUnsafeMutableBytes { SystemCalls.socketRead(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                deliver(Data(bytes.prefix(count)))
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close()
                return
            }
        }
    }

    /// Writes one line, newline appended. Silently does nothing once the connection is closed,
    /// because every caller of this is answering something and there is nothing useful for it to
    /// do about a far end that has already gone.
    public func writeLine(_ text: String) {
        guard !closed.withLock({ $0 }) else { return }
        var payload = Array(text.utf8)
        if payload.last != UInt8(ascii: "\n") { payload.append(UInt8(ascii: "\n")) }

        writer.withLock { _ in
            let output = closed.withLock { closed in closed ? -1 : fcntl(descriptor, F_DUPFD_CLOEXEC, 0) }
            guard output >= 0 else { close(); return }
            defer { SystemCalls.close(output) }
            var offset = 0
            var deadline = ContinuousClock.now + writeTimeout
            while offset < payload.count {
                // send is nonblocking and protected against close. Poll uses an owned duplicate
                // outside that lock, so a waiting writer cannot starve shutdown or touch a reused FD.
                let written: Int = closed.withLock { closed in
                    guard !closed else { return -1 }
                    let count = payload.withUnsafeBufferPointer { bytes in
                        #if os(Linux)
                        Glibc.send(output, bytes.baseAddress! + offset, bytes.count - offset, Int32(MSG_NOSIGNAL | MSG_DONTWAIT))
                        #else
                        Darwin.send(output, bytes.baseAddress! + offset, bytes.count - offset, MSG_DONTWAIT)
                        #endif
                    }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        return 0
                    }
                    if count < 0, errno == EINTR { return 0 }
                    return count > 0 ? count : -1
                }
                if written < 0 { close(); return }
                if written > 0 { offset += written; deadline = .now + writeTimeout } else {
                    var ready = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&ready, 1, 50)
                }
                if ContinuousClock.now >= deadline { close(); return }
            }
        }
    }

    /// Waiting for a slow peer must not occupy an actor or a Swift cooperative executor thread.
    /// Cancellation of an MCP call still needs to deliver its result, so connection lifetime,
    /// rather than the caller's cancellation bit, decides whether to discard an awaiting write.
    public func writeLineAsync(_ text: String) async {
        await withCheckedContinuation { continuation in
            writeQueue.async {
                self.writeLine(text)
                continuation.resume()
            }
        }
    }

    public func close() {
        let claimed = closed.withLock { closed -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        guard claimed else { return }

        source.withLock { $0?.cancel() }
        continuation.finish()
    }

    deinit { close() }
}
