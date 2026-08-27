import Foundation

/// What one entry of a drawn transcript is: a stored row, or one of the five things that are not
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
    /// The line above a run of consecutive tool calls, by the sequence number of the FIRST call in
    /// it. See `TranscriptFold`.
    ///
    /// **It is in the list from the run's second call onwards, whether it is folded or not, and
    /// drawing nothing when it is not.** That is the same argument the four singletons below carry
    /// and it is the whole reason folding is cheap: an entry that came and went in the middle of
    /// the list would make the pass that folds a run both an insertion and a removal, which
    /// `TranscriptEntryChange` can only answer `.rebuilt` to. In place before the run is long
    /// enough to fold, folding is a removal on its own and unfolding is an insertion on its own.
    /// See `TranscriptFold.leastGroup`, which is that gap.
    case fold(Int)
    /// The bubble drawn from the moment Return is pressed until its stored row arrives. Its own
    /// case rather than a row, so that the stored row taking its place is an entry the table has
    /// not seen: that makes the swap a replacement rather than a row changing under the reader.
    case sending
    /// The per-token tail of a running turn.
    case streaming
    /// A queued message, waiting to be sent.
    case pending(DeliveryID)

    /// The sequence number this entry names, or nothing for the five that are not stored rows.
    ///
    /// What the pane writes down as the reader's place. Nothing else may guess at it: the whole
    /// point of the type is that a caller cannot mistake the streaming tail for row zero. A fold
    /// answers nothing here even though it holds a number, because the number is the identity of
    /// a run rather than a row the reader can be put back on: the row it names is usually the one
    /// the fold is hiding.
    public var seq: Int? {
        guard case .row(let seq) = self else { return nil }
        return seq
    }

    /// **Whether this entry can change what it draws without its content key moving.**
    ///
    /// A stored row cannot: everything that changes what one draws is hashed into its key, so a
    /// row that has been measured is measured until the key moves. The four that are not stored
    /// rows all can, because each re-renders from its own observation inside the cell it is in.
    /// The streaming tail is the one that bites: it draws nothing at all between turns, so
    /// anything that treats "measured at nought" as "will always be nought" would leave a running
    /// turn with no view to appear in.
    ///
    /// Here rather than beside the table because it is a claim about these six cases, and a
    /// caller acting on it is deciding whether to build a row's view at all.
    ///
    /// **This used to be `seq == nil`, and the coincidence ended with `fold`.** A fold's line
    /// names no stored row, so it has no sequence number, and it cannot redraw itself either: what
    /// it says is hashed into its content key like any row's, so measuring it at nought is a
    /// promise that holds until the key moves.
    public var redrawsItself: Bool {
        switch self {
        case .row, .fold: false
        case .setup, .sending, .streaming, .pending: true
        }
    }

    public var description: String {
        switch self {
        case .setup: "setup"
        case .row(let seq): "row.\(seq)"
        case .fold(let seq): "fold.\(seq)"
        case .sending: "sending"
        case .streaming: "streaming"
        case .pending(let id): "pending.\(id)"
        }
    }
}
