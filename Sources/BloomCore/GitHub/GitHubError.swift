import Foundation

/// GitHub failures retain command context or invalid output without exposing unbounded output.
public struct GitHubError: Error, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
