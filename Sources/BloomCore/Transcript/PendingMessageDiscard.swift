import Foundation

/// Taking a queued message back out before it is said, and what becomes of the words.
///
/// The queue already had one way out: `Store.cancelDelivery`. What it did not have was an answer
/// to the two questions somebody actually asks when they reach for it, which are "is this really
/// going to be thrown away" and "where did my sentence go". Both are decisions rather than
/// drawings, so they are here, where the suite can see them, and the view is left with nothing to
/// invent. See the head of `Delivery` for why the queue is a table in the first place.
public enum PendingMessageDiscard {
    /// Whether this one may still be taken back.
    ///
    /// A delivery that has gone is a turn the agent is already running, and deleting the row would
    /// not unsay it. `Store.cancelDelivery` holds the same rule in its `WHERE`, which is what makes
    /// the two answers agree on the frame the drain fires.
    public static func canDiscard(_ delivery: Delivery) -> Bool { delivery.isPending }

    // MARK: - The words

    /// What becomes of the sentence when the queued message goes.
    public enum Recovery: Equatable, Sendable {
        /// It goes back into the composer, where it can be read, edited and sent again.
        case toComposer(String)
        /// It is thrown away, and the confirmation is the only thing standing in front of that.
        case discarded(Reason)

        /// Why the words could not be handed back.
        ///
        /// Not drawn anywhere today: both reasons produce the same sentence, because "it is not
        /// kept" is the whole of what a reader has to weigh and the mechanism behind it changes
        /// nothing about the decision. They are separate cases so the suite can say which rule
        /// fired, which is the part that would otherwise be untestable.
        public enum Reason: Equatable, Sendable {
            /// The composer already holds something. Pasting over what somebody is typing to
            /// rescue what they typed earlier trades one loss for another, and `TranscriptModel`
            /// refused exactly that trade when a failed send used to push its prompt back into
            /// the box.
            case composerInUse
            /// The body is not only typed words: it carries review chips or attached files, which
            /// the composer cannot be handed back as text. Putting the rendered prompt in there
            /// would be putting a machine's writing in the owner's box.
            case notPlainText
        }
    }

    /// What would become of this message's words, if it were discarded right now.
    ///
    /// `composerDraft` is what is in the box at that moment, and blank counts as empty: a box
    /// holding three newlines is not something anybody is in the middle of writing.
    public static func recovery(of delivery: Delivery, composerDraft: String) -> Recovery {
        guard isPlainText(delivery.body) else { return .discarded(.notPlainText) }
        guard composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .discarded(.composerInUse)
        }
        return .toComposer(delivery.body)
    }

    /// Whether a body is the owner's words and nothing else.
    ///
    /// Both trailers are machine writing appended at send time, and neither survives a round trip
    /// through a text box: the chips would come back as their rendered prompt, and the attachment
    /// paths would come back as a list the composer draws from its own staging instead.
    ///
    /// `PendingMessageEdit` asks this too, and it is the one question the two of them share: it is
    /// a fact about the body, where everything else here is a policy about the box.
    public static func isPlainText(_ body: String) -> Bool {
        ReviewTurn.split(body) == nil && AttachmentTrailer.split(body).paths.isEmpty
    }

    // MARK: - The question

    /// One confirmation's worth of words. The app owns the dialog; these are the sentences in it.
    public struct Question: Equatable, Sendable {
        public var title: String
        public var message: String
        public var confirmLabel: String
        public var cancelLabel: String

        public init(title: String, message: String, confirmLabel: String, cancelLabel: String) {
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
        }
    }

    /// What to ask before throwing a queued message away.
    ///
    /// The message says what happens to the words rather than "this cannot be undone", because
    /// which of the two it is decides the answer: handing the sentence back to the composer is a
    /// tidy-up, and losing minutes of thought is not, and a dialog that read the same either way
    /// would be teaching the owner to click through it.
    public static func question(for recovery: Recovery) -> Question {
        let message =
            switch recovery {
            case .toComposer:
                "It leaves the queue without being sent, and its text goes back to the composer."
            case .discarded:
                "It leaves the queue without being sent, and its text is not kept."
            }
        return Question(
            title: "Delete this message?",
            message: message,
            confirmLabel: "Delete",
            cancelLabel: "Keep"
        )
    }

    /// What the owner is told when the message went while the question was still on screen.
    ///
    /// The race is real and it is not rare: the hold clears the instant the agent's turn ends, and
    /// the drain fires on that event rather than on a clock. The delete deliberately LOSES it. By
    /// then the sentence is a turn the agent is already running, so there is nothing left to take
    /// back and a delete that reported success would be a lie about what the agent can see.
    /// Saying so is the whole of the handling: the dialog goes, and this arrives in the corner.
    public static let alreadySentSentence =
        "That message had already gone to the agent, so it was not deleted."
}
