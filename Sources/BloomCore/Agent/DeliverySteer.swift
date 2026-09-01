import Foundation

/// Stopping the turn that is running so that one queued message goes now.
///
/// The queue moves in one direction and one at a time, which is what makes the order it hands
/// things over the order they were asked for (see `Delivery`). Steer is the one thing a person is
/// allowed to do to that order, and it is deliberately not a reordering: the message pressed
/// **leaves** the queue, into the turn it just made room for, and everything else keeps both its
/// place and its place in line behind it.
///
/// That is the difference between this and dragging a row to the top. A queue somebody can shuffle
/// is a queue whose order is a guess again, which is the bug the table was built to end; a queue
/// somebody can take one message out of, in front of him, with the turn it interrupts named on the
/// button, holds its promise for everything still in it.
public enum DeliverySteer {
    /// Whether Steer may be offered for this message at all.
    ///
    /// **Only while a turn is actually running**, because stopping is the whole first half of what
    /// the button does and there is nothing to stop otherwise. The other three holds each say what
    /// they are waiting on and none of them is answered by a Stop: a setup script is not stopped by
    /// interrupting an agent that has not started, a permission question above the composer is a
    /// thing to answer rather than to talk over, and a queue nothing is holding needs no button at
    /// all, since the message at the front of it is already on its way.
    ///
    /// The kind is asked as well, for the reason `PendingMessageReturn.canReturn` asks it: the row
    /// this is drawn on is only ever the owner's own, and deciding to interrupt an agent is a
    /// person's decision rather than another agent's. A body carrying chips or attachments is fine
    /// here, unlike Edit, because nothing is being turned back into text: the message goes to the
    /// agent exactly as it would have gone when its turn came.
    public static func canSteer(_ delivery: Delivery, hold: DeliveryHold) -> Bool {
        guard hold == .turn else { return false }
        return delivery.isPending && delivery.kind == .owner && delivery.crewPayload == nil
    }

    /// The queue as it stands once `chosen` has been steered out of it.
    ///
    /// Everything else, in the order it was asked for, which is the whole of the ordering rule and
    /// the reason it is a function rather than a sentence in a comment. Nothing is promoted and
    /// nothing is delayed: the next turn to end drains the front of what is left, exactly as it
    /// would have without the interruption.
    public static func queue(after chosen: Delivery, from pending: [Delivery]) -> [Delivery] {
        pending.filter { $0.id != chosen.id }
    }
}
