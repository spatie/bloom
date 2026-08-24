import Foundation

/// What a session Bloom was writing to turns out to be, asked once a write has already failed.
///
/// The sibling of `CheckoutStanding`, and it exists for the same reason. A store write that fails
/// tells the caller almost nothing on its own: SQLite says "FOREIGN KEY constraint failed" for a
/// row whose session was deleted a moment ago and for a database whose schema is genuinely
/// broken, and those two deserve opposite treatment. So the question is put to the database
/// rather than to its complaint: is the row this write hangs from still there?
///
/// It cannot be answered by looking at the error, and it must not be. `messages.session_id` and
/// `permission_asks.session_id` both cascade from `sessions`, which cascades from `workspaces`,
/// so archiving or removing a workspace under a turn that is still in flight takes the session
/// row with it and the very next row the agent writes is refused. That is not a fault. Every
/// other refusal is.
public enum TranscriptStanding: Sendable, Equatable {
    /// The session row is still in the database, so whatever refused the write refused it for
    /// some other reason.
    case there
    /// The session row has gone, which is what a workspace removed under a running agent looks
    /// like from inside the runner.
    case gone
    /// The database could not even be asked, which is itself a fault worth reporting.
    case unanswerable

    /// Asks the database, rather than reading what it said about the write that failed.
    public static func of(sessionID: SessionID, in store: Store) async -> TranscriptStanding {
        do {
            return try await store.session(id: sessionID) == nil ? .gone : .there
        } catch {
            return .unanswerable
        }
    }

    /// The database's complaint without the statement Bloom built to provoke it.
    ///
    /// The exact counterpart of `CheckoutStanding.complaint(about:)`, and written because the same
    /// mistake had been made again in a different vocabulary. `SQLiteError.description` appends the
    /// SQL, so `error.readableMessage` on a refused write is "FOREIGN KEY constraint failed [INSERT
    /// INTO messages (session_id, seq, kind, payload, created_at, duration_ms, ref_id) VALUES (?,
    /// ?, ?, ?, ?, ?, ?)]", and that went straight into a modal. Seven question marks say nothing
    /// to anybody: the reader neither wrote that statement nor can change it. The description is
    /// the right thing for a log and the wrong thing for a person, exactly as `ShellError`'s is.
    public static func complaint(about error: any Error) -> String {
        guard let sqlite = error as? SQLiteError else { return error.readableMessage }
        let message = sqlite.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "The database refused the write without saying why." }
        return message.hasSuffix(".") ? message : message + "."
    }
}
