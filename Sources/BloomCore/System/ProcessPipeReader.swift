import Foundation
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A reader owns a duplicate descriptor until EOF. Foundation can retire its original handles
/// when the child exits without invalidating a thread still collecting that child's output.
final class ProcessPipeReader: Sendable {
    private let descriptor: Int32
    private let closed = Mutex(false)

    init(_ handle: FileHandle) throws {
        descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// A readability callback must not fill a requested byte count or trap on EINTR, both of
    /// which Foundation's convenience readers can do. Nil means readiness was already consumed;
    /// empty Data means EOF. The duplicate keeps the descriptor owned until the read finishes.
    static func available(from handle: FileHandle) throws -> Data? {
        let reader = try ProcessPipeReader(handle)
        defer { reader.close() }
        return try reader.next(timeoutMilliseconds: 0)
    }

    func next(timeoutMilliseconds: Int32 = -1) throws -> Data? {
        guard !closed.withLock({ $0 }) else { throw POSIXError(.EBADF) }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = poll(&event, 1, timeoutMilliseconds)
            if result == 0 { return nil }
            if result > 0 { break }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = bytes.withUnsafeMutableBytes { SystemCalls.read(descriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func close() {
        let claimed = closed.withLock { closed -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        if claimed { SystemCalls.close(descriptor) }
    }

    deinit { close() }
}
