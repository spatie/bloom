import Foundation

/// A message somebody has asked for that has not gone to the agent yet.
///
/// **One ordered queue, and every route into a conversation goes through it.** There used to be
/// two: the opening prompt typed in the create window waited inside
/// `WorkspaceModel.runSetupThenSend` for the setup script to finish, while anything typed into the
/// composer during that minute went straight to the runner, because nothing marks a session busy
/// while its worktree is being set up. Whichever the scheduler reached first won, and the owner
/// watched a workspace answer a question he typed second before the one he opened it with. The
/// transcript read "test" and then "list the technologies used", in that order, which is the
/// reverse of the order he asked for them.
///
/// So the composer no longer sends. It enqueues, and a drain sends. Ordering is then a property of
/// one table with one order rather than an accident of which continuation resumed first, and it
/// holds for a source that does not exist yet as easily as for the two that do.
///
/// **This is the `deliveries` queue in `bloom-handover/mcp-design.md`, not a second one beside
/// it.** That design specifies a persistent queue for a message arriving at a session that is
/// busy, delivered when the turn ends, carrying both a child workspace's report and a
/// `workspace_send` body. That is the same shape and the same drain point as a person typing while
/// a turn runs, so it is the same queue, built once, with `Kind` saying who asked. The columns
/// that half will need are in the table already: see the migration in `Store`.
///
/// A delivery is deliberately NOT a `messages` row while it is pending. Nothing an agent sees may
/// contain a sentence nobody has sent it yet, which is the same property `WorkspaceEvent` holds
/// for the rows Bloom draws about a workspace. It becomes a `messages` row at the moment it goes,
/// written by the runner, exactly as a typed prompt always was.
public struct Delivery: Identifiable, Sendable, Hashable {
    /// Who asked, which is what a reader has to be told and what decides how the turn is framed.
    ///
    /// `message` and `report` are the MCP design's two, kept under its spellings so the rows this
    /// half writes and the rows that half will write live in one table with one vocabulary.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The person: the create window's opening prompt, the composer, a notification reply.
        case owner
        /// Another workspace's agent, through `workspace_send`.
        case message
        /// A child workspace's finished report.
        case report
    }

    public var id: DeliveryID
    /// The conversation this is addressed to, resolved when it was asked for rather than when it
    /// goes. A workspace can hold several chats, so a message addressed to a workspace is
    /// addressed to nobody deliverable.
    public var targetSessionID: SessionID
    /// The workspace whose agent asked, for the two agent kinds. Nil for the owner.
    public var sourceWorkspaceID: WorkspaceID?
    public var kind: Kind
    /// Reports only: done, blocked or failed. Nil for everything else.
    public var verdict: String?
    /// What a person reads. For a crew message that is the agent's own words, without the
    /// envelope: see `crewPayload`.
    public var body: String
    /// The `CrewMessage` this delivery is, encoded, or nil for a sentence the owner typed.
    ///
    /// **The two halves have to travel together or the bug comes back.** A message from one agent
    /// to another is wrapped for the model and read by a person, and those are two different
    /// strings. A delivery that carried only one of them left the drain choosing between handing
    /// the model an unwrapped sentence and drawing the envelope in the owner's own bubble, which
    /// is what it did.
    ///
    /// Bytes rather than a `CrewMessage`, for two reasons. A `Delivery` is `Hashable` and a
    /// `CrewMessage` is not, and these are the exact bytes the `messages` row is written with, so
    /// the queue and the transcript cannot disagree about what was said.
    public var crewPayload: Data?
    public var createdAt: Date
    /// Nil while it is still waiting. Set at the moment it goes.
    public var deliveredAt: Date?
    /// The `messages.seq` this became, where the caller knows it.
    ///
    /// Nil for the owner's own turns, and that is honest rather than an omission: the runner
    /// writes the user row as part of starting the turn, so the seq is not known on the side of
    /// the call that sends. The MCP half writes its own row through `Store.appendNext` and has
    /// the number in its hand.
    public var deliveredSeq: Int?

    public init(
        id: DeliveryID = .new(),
        targetSessionID: SessionID,
        sourceWorkspaceID: WorkspaceID? = nil,
        kind: Kind = .owner,
        verdict: String? = nil,
        body: String,
        crewPayload: Data? = nil,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        deliveredSeq: Int? = nil
    ) {
        self.id = id
        self.targetSessionID = targetSessionID
        self.sourceWorkspaceID = sourceWorkspaceID
        self.kind = kind
        self.verdict = verdict
        self.body = body
        self.crewPayload = crewPayload
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.deliveredSeq = deliveredSeq
    }

    /// A delivery of something one agent said to another, or of Bloom's word about one of them.
    ///
    /// The only way to build one, so that `body` cannot be given the envelope by a caller that
    /// meant the words. Every crew message in the app goes through here.
    ///
    /// An encoding failure leaves `crewPayload` nil, which costs the header on the row and sends
    /// the readable half rather than losing the sentence. It cannot realistically happen: the
    /// payload is five strings and two enums with `String` raw values.
    public init(
        id: DeliveryID = .new(),
        targetSessionID: SessionID,
        sourceWorkspaceID: WorkspaceID? = nil,
        kind: Kind,
        verdict: String? = nil,
        crew message: CrewMessage,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            targetSessionID: targetSessionID,
            sourceWorkspaceID: sourceWorkspaceID,
            kind: kind,
            verdict: verdict,
            body: message.text,
            crewPayload: try? message.payload(),
            createdAt: createdAt
        )
    }

    /// The message this is, for a caller that has to read one half of it. Nil for the owner's own.
    public var crewMessage: CrewMessage? { crewPayload.flatMap(CrewMessage.decode) }

    /// What the agent is actually handed, which is the envelope for anything another agent said
    /// and the body itself for everything else.
    ///
    /// The drain asks this rather than reaching for `body`, which is the whole of the fix: one
    /// place decides which of the two renderings goes to the model.
    public var sent: String { crewMessage?.sent ?? body }

    public var isPending: Bool { deliveredAt == nil }

    /// Which of the waiting messages goes next, if any may go at all.
    ///
    /// The front of the queue, always, and never the one that was just typed. That is the whole of
    /// the ordering rule and the reason it is a function rather than two lines inside a view
    /// model: the two routes into a chat used to make this decision separately, and the answer
    /// they disagreed about is the bug. See the note at the top of this file.
    ///
    /// `pending` must be in the order `Store.pendingDeliveries` returns, which is the order it was
    /// asked for.
    public static func next(from pending: [Delivery], hold: DeliveryHold) -> Delivery? {
        guard hold.allowsDelivery else { return nil }
        return pending.first
    }

    /// Whether something enqueued this instant would go straight out, with nothing in front of it.
    ///
    /// **This is what the transcript has to know on the frame Return is pressed.** A message that
    /// is about to go has been said, and is drawn as an ordinary user bubble from that frame; a
    /// message that will wait is drawn as the pending one, which says why it is waiting. Getting
    /// that wrong either way is visible: a dotted bubble that turns solid a few milliseconds
    /// later, or a bubble that claims to have gone and then sits there for a minute of setup.
    ///
    /// Asked of the same function the drain asks, rather than by restating the rule, because the
    /// two answers disagreeing is the whole class of bug this file exists to close. `pending` is
    /// the queue as it stands **before** the new message joins it.
    public static func goesImmediately(behind pending: [Delivery], hold: DeliveryHold) -> Bool {
        // Nothing may go at all, so nor may this one.
        guard hold.allowsDelivery else { return false }
        // Anything already waiting is in front of it, and the front of the queue always wins.
        return next(from: pending, hold: hold) == nil
    }
}
