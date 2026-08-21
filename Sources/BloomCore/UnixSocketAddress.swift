import Foundation

/// The one piece of arithmetic in the bridge that the kernel will not complain about if it is
/// wrong.
///
/// `sockaddr_un.sun_path` is a fixed 104 byte array on Darwin, and a path that does not fit is
/// **truncated rather than refused**: the bind succeeds against a shorter name, so two processes
/// whose paths agree for the first 103 bytes end up sharing one socket and nothing anywhere says
/// so. `BridgeSocketPath` keeps the derived path short; this refuses anything that got past it,
/// including a path a test or a future caller built by hand.
enum UnixSocketAddress {
    static func make(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw UnixSocketError.pathTooLong(path: path, limit: capacity)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    /// Calls `body` with the address cast to the `sockaddr` every socket call wants.
    static func withSocketAddress<Result>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

enum UnixSocketError: Error, CustomStringConvertible {
    case pathTooLong(path: String, limit: Int)
    case couldNotOpen(code: Int32)
    case couldNotBind(path: String, code: Int32)
    case couldNotListen(path: String, code: Int32)
    case couldNotConnect(path: String, code: Int32)

    var description: String {
        switch self {
        case .pathTooLong(let path, let limit):
            "\(path) is \(path.utf8.count) bytes and a unix socket name may be at most \(limit - 1)"
        case .couldNotOpen(let code):
            "could not open a unix socket: \(Self.reason(code))"
        case .couldNotBind(let path, let code):
            "could not bind \(path): \(Self.reason(code))"
        case .couldNotListen(let path, let code):
            "could not listen on \(path): \(Self.reason(code))"
        case .couldNotConnect(let path, let code):
            "could not connect to \(path): \(Self.reason(code))"
        }
    }

    private static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
