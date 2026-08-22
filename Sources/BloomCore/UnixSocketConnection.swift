import Foundation
import Synchronization

/// One end of a connected unix domain socket, read as lines and written as lines.
///
/// Line delimited JSON both ways, because that is what MCP over stdio already is and the shim is a
/// relay: whatever the CLI wrote on one line arrives here as one line and goes back the same way.
///
/// `SO_NOSIGPIPE` is set on every socket this type owns, and it is not optional. Writing to a
/// socket whose far end has gone raises SIGPIPE, whose default disposition kills the process, so
/// without it Bloom would be taken down by an agent CLI exiting mid-call. With it the write
/// returns EPIPE and the connection closes, which is what "the other side left" should look like.
public final class UnixSocketConnection: Sendable {
    private let descriptor: Int32
    private let handle: FileHandle
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
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Blocking, explicitly. On BSD, and therefore on macOS, an accepted socket inherits
        // O_NONBLOCK from the listener, and the listener has to be non-blocking so its accept loop
        // can drain. `availableData` on a non-blocking descriptor answers with no bytes when there
        // are none yet, which reads exactly like end of file, so an inherited flag would close
        // every connection the moment it went quiet.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) & ~O_NONBLOCK)

        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                close()
                return
            }
            deliver(data)
        }
    }

    /// Connects to a listening socket, or says why it could not.
    ///
    /// No retry and no wait. The ordinary reason this fails is that Bloom has quit and somebody is
    /// running the CLI by hand, and the right answer to that is one sentence immediately rather
    /// than a tool call that hangs for a timeout the model cannot see.
    public static func connect(to path: String) throws -> UnixSocketConnection {
        var address = try UnixSocketAddress.make(path: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.couldNotOpen(code: errno) }

        let result = UnixSocketAddress.withSocketAddress(&address) { socketAddress, length in
            Darwin.connect(descriptor, socketAddress, length)
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixSocketError.couldNotConnect(path: path, code: code)
        }
        return UnixSocketConnection(descriptor: descriptor)
    }

    private func deliver(_ data: Data) {
        for line in buffer.take(data) { continuation.yield(line) }
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
                    Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
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

        handle.readabilityHandler = nil
        continuation.finish()
        Darwin.close(descriptor)
    }
}
