import BloomCore

/// A git failure carried back across a task boundary. `any Error` is not `Sendable`, and the only
/// part of it the UI shows is the message.
struct GitFailure: Error, Sendable {
    var message: String
}
