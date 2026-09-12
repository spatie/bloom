import Foundation
#if os(Linux)
import Glibc
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

    /// Lines from the far end, ending when it closes. Unbounded, because every line is a request
    /// or a reply and dropping one strands whoever is waiting for it.
    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(descriptor: Int32) {
        self.descriptor = descriptor
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)

        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Writes remain blocking; reads use MSG_DONTWAIT so draining never parks the queue.
        // BSD accepted sockets inherit O_NONBLOCK from the listener.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) & ~O_NONBLOCK)

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
        var payload = Array(text.utf8)
        if payload.last != UInt8(ascii: "\n") { payload.append(UInt8(ascii: "\n")) }

        closed.withLock { closed in
            guard !closed else { return }
            var offset = 0
            while offset < payload.count {
                let written = payload.withUnsafeBufferPointer { bytes in
                    SystemCalls.socketWrite(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                }
                // EINTR is a signal landing mid-write and nothing else, so the same bytes are
                // written again. Any other failure means the far end is gone and there is nothing
                // to retry.
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
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
