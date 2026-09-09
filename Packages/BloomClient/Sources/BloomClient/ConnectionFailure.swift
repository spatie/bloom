import Foundation

public struct ConnectionFailure: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// An explicit HTTP or server refusal. This does not prove an earlier attempt never executed:
/// a server failure can report an incomplete command journal after a process interruption.
public struct ConnectionRefusal: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
