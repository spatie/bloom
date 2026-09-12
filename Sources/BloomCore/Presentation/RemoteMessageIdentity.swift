/// SQLite row IDs are unique only inside their owning database. Shared transcript caches use
/// those IDs, so remote messages need process-wide presentation IDs distinct from local rows.
/// The wire sequence and session identity stay unchanged for paging and server actions.
@MainActor
public final class RemoteMessageIdentity {
    private static var nextID: Int64 = -1
    private var identities: [Int64: Int64] = [:]

    public init() {}

    /// Reset when switching databases. Previously issued IDs are never reused by another host.
    public func reset() { identities.removeAll() }

    public func presentation(_ message: Message) -> Message {
        var result = message
        if let existing = identities[message.id] {
            result.id = existing
        } else {
            result.id = Self.nextID
            identities[message.id] = result.id
            Self.nextID -= 1
        }
        return result
    }
}
