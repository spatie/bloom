import Foundation

/// What one entry of a drawn transcript is: a stored row, or one of the four things that are not
/// stored rows.
///
/// **A type rather than the `String` the spike had, and the reason is the one `Identifier.swift`
/// gives for every other id in this app.** A drawn transcript names five different things, and
/// four of them are singletons whose id was a bare literal: `"setup"`, `"sending"`,
/// `"streaming"`, and `"pending.<id>"` beside `"row.<seq>"`. Every lookup then went through a
/// dictionary of strings, and getting a row's seq back out meant `Int(id.dropFirst(4))`, which is
/// a parse that can fail and had no case for failing. A row and a delivery could be spelled into
/// each other by one wrong prefix and nothing would have objected.
///
/// The seq is a plain `Int` because that is what a `TranscriptRow.seq` is throughout: it is an
/// ordinal within one session rather than an identity across the app, which is why it has never
/// had a wrapper and does not get one here.
public enum TranscriptEntryID: Hashable, Sendable, CustomStringConvertible {
    /// The workspace's own setup log, drawn before anything can have been said.
    case setup
    /// A stored row, by its sequence number within the session.
    case row(Int)
    /// The bubble drawn from the moment Return is pressed until its stored row arrives. Its own
    /// case rather than a row, so that the stored row taking its place is an entry the table has
    /// not seen: that makes the swap a replacement rather than a row changing under the reader.
    case sending
    /// The per-token tail of a running turn.
    case streaming
    /// A queued message, waiting to be sent.
    case pending(DeliveryID)

    /// The sequence number this entry names, or nothing for the four that are not stored rows.
    ///
    /// What the pane writes down as the reader's place. Nothing else may guess at it: the whole
    /// point of the type is that a caller cannot mistake the streaming tail for row zero.
    public var seq: Int? {
        guard case .row(let seq) = self else { return nil }
        return seq
    }

    public var description: String {
        switch self {
        case .setup: "setup"
        case .row(let seq): "row.\(seq)"
        case .sending: "sending"
        case .streaming: "streaming"
        case .pending(let id): "pending.\(id)"
        }
    }
}
