import Foundation

/// Giving the queue back to the owner when he stops a turn by hand.
///
/// **This is the promise the dotted bubble could not keep.** Stop is somebody stepping in, so the
/// drain deliberately does not run on the result a cancellation produces: see
/// `TranscriptModel.wasStoppedByHand`, which is right and stays. What it was not was the whole
/// answer. The message typed four minutes ago went on sitting under the transcript, and the
/// sentence beneath it had been saying "Goes when this turn ends." The turn ended. It did not go,
/// and nothing on screen ever said so again, because a queue nothing is holding says nothing at
/// all (`DeliveryHold.sentence(on:)` answers nil for a hold that is holding nothing).
///
/// **A backend that takes a message mid turn does not reopen this.** A running turn holds nothing
/// there, so the queue empties into it rather than sitting under a promise; what is left after a
/// Stop is the queue this type is about, under no sentence at all, exactly as before.
///
/// So Stop hands the words back to the composer, where they are his to change, send again or
/// throw away, and where no bubble is making a promise on their behalf. It is the move
/// `PendingMessageEdit` already makes for one message pressed by hand, taken over the queue at
/// once, and it shares that type's reading of what may travel as text rather than inventing a
/// second one.
///
/// The alternative was returning only the front message and leaving the rest queued. That is the
/// same bug for every message but the first, and the loss it avoids is not a loss: the words all
/// arrive in the box, in order, and a person who wants them sent as two turns still has both
/// sentences in front of him to split. Stranding four minutes of typing to preserve a paragraph
/// break is the wrong trade.
public enum PendingMessageReturn {
    /// Whether this one may come back into the composer as text.
    ///
    /// **A crew message is not the owner's writing and must never land in his box.** Its body is
    /// another agent's sentence, and the pending row that carries Edit and Delete is never drawn
    /// for one: `TranscriptListView` sends it to `CrewMessageRowView` instead, which is why
    /// `PendingMessageEdit.canEdit` never had to ask. Something that walks the whole queue does
    /// have to ask, because the one table holds both.
    ///
    /// The rest is `PendingMessageEdit`'s answer unchanged: a body carrying review chips or
    /// attached files cannot round trip through a text box, so it stays where it is rather than
    /// coming back as the machine's rendering of itself. It keeps its place and its order, and the
    /// owner still has Delete on it.
    public static func canReturn(_ delivery: Delivery) -> Bool {
        delivery.kind == .owner
            && delivery.crewPayload == nil
            && PendingMessageEdit.canEdit(delivery)
    }

    /// Everything in the queue that is going back to the composer, in the order it was asked for.
    public static func returning(from pending: [Delivery]) -> [Delivery] {
        pending.filter(canReturn)
    }

    /// Everything that stays queued, in the order it was asked for.
    ///
    /// The complement of `returning`, named rather than left for each caller to work out, because
    /// "what is still waiting after a Stop" is the half a reader doubts and the half a test has to
    /// be able to state.
    public static func keeping(from pending: [Delivery]) -> [Delivery] {
        pending.filter { !canReturn($0) }
    }

    /// What the composer is left holding once these have left the queue.
    ///
    /// The queue's own order, and everything the box already held goes last: the draft is the
    /// newest thing typed and the queue is older than all of it, so oldest first puts them in the
    /// order they were written. Nothing is overwritten, which is the rule Delete already holds to
    /// when it refuses to paste over a box in use.
    ///
    /// Folded through `PendingMessageEdit.draft` rather than joined here, so that returning a
    /// queue of one is the same operation as pressing the pencil on it, by construction rather
    /// than by two functions agreeing today.
    public static func draft(taking deliveries: [Delivery], into composerDraft: String) -> String {
        deliveries.reversed().reduce(composerDraft) {
            PendingMessageEdit.draft(taking: $1, into: $0)
        }
    }
}
