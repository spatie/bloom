import Foundation

public struct ConnectionFailure: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// A refusal has a known outcome. A transport failure may follow a completed command.
public struct ConnectionRefusal: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
