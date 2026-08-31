import SwiftUI
import Observation
import BloomCore

/// One renderable row in a transcript.
///
/// It deliberately carries the raw JSON rather than a decoded structure. The store keeps every
/// event verbatim, so a renderer added later can show detail that was not decoded when the row
/// was written, and a row costs nothing to hold until it scrolls into view.
struct TranscriptRow: Identifiable, Hashable {
    var id: Int64
    var seq: Int
    var kind: MessageKind
    var payload: Data
    var createdAt: Date
    var durationMS: Int?
    var refID: String?

    /// Set once the matching tool_result arrives, so a tool call and its outcome render as one row.
    var resultPayload: Data?
    var isError = false
    /// Set when the result says the call never ran, and why. A refusal carries `is_error` as well,
    /// so the two are held together and every reader that draws a failure checks this first.
    var refusal: ToolRefusal?
    /// The one line the CLI gave for a refusal, so a collapsed row can say what happened without
    /// decoding a result payload that is usually the largest in the session.
    var refusalReason = ""
    /// Non-nil when the row came from inside a subagent, so it can be indented under its parent.
    var parentToolUseID: String?

    /// For a `permissionAsk` row: how the question was settled, or nil while it is still open.
    ///
    /// Held on the row rather than looked up per frame, because the answer decides whether the row
    /// draws live buttons, and a row that offers buttons for a question already answered would
    /// write into a pipe nobody is reading.
    var permissionDecision: String?
    /// What the transcript should say about how it was settled, when that is not obvious. Only
    /// ever set for a question a rule answered rather than a person.
    var permissionNote = ""

    init(message: Message) {
        id = message.id
        seq = message.seq
        kind = message.kind
        payload = message.payload
        createdAt = message.createdAt
        durationMS = message.durationMS
        refID = message.refID
    }
}

/// The state behind one session's transcript: the rows, whether the agent is running, and the
/// partial text currently streaming in.
@MainActor
@Observable
final class TranscriptModel {
    private struct RunnerPreferences: Equatable {
        var model: String
        var effort: String
        var permissionMode: String
        var agentKind: String

        init(session: Session) {
            model = session.model
            effort = session.effort
            permissionMode = session.permissionMode.rawValue
            agentKind = session.agentKind.rawValue
        }
    }

    var session: Session
    /// The workspace as it was when this model was made, or nil for a chat that is in none.
    ///
    /// **Nil is Ask Bloom and nothing else today.** Its id and path are stable and are what most
    /// of the file needs; its name is not, and anything said out loud reads `workspaceNow`. Every
    /// reader of this is a thing a worktree has and this chat does not: an inspector, a diff, an
    /// unread mark, a notification that names a place. Each of them now says nothing rather than
    /// saying it about a workspace that was invented to keep the type non-optional.
    let workspace: Workspace?
    /// Where this chat's agent runs. The worktree, when there is one, and Ask Bloom's own empty
    /// directory when there is not. See `AskConversation.directory`, which argues at length why
    /// that directory is empty rather than the owner's home.
    let cwd: String
    private unowned let app: AppModel

    /// Where this conversation's file paths point, and which workspace a file chip opens into.
    /// One value rather than the whole workspace, because those two fields are all a row has ever
    /// read off it. See `TranscriptHome`.
    var home: TranscriptHome {
        TranscriptHome(workspaceID: workspace?.id, worktree: cwd)
    }

    /// The row as the app holds it now. The snapshot above goes stale the moment automatic
    /// naming lands, minutes into the workspace's life, and every alert and notification from
    /// this chat then called the workspace by its ocean placeholder for the rest of the launch.
    private var workspaceNow: Workspace? {
        guard let workspace else { return nil }
        return app.existingModel(for: workspace.id)?.workspace ?? workspace
    }

    private(set) var rows: [TranscriptRow] = []
    /// Whether this session's agent is mid turn.
    ///
    /// Computed over one stored flag rather than being the stored flag, so that every change to
    /// it goes through `setRunning` and the app can be told. Reading it still registers a
    /// dependency on `storedIsRunning`, which is what a view needs.
    var isRunning: Bool { storedIsRunning }
    private var storedIsRunning = false

    /// Whether this session's agent has stopped and is waiting on a person.
    ///
    /// A stored flag for exactly the reason `isRunning` is one, and not a walk over `rows` looking
    /// for an unanswered question. `rows` is observable, so a derived answer would technically
    /// invalidate, but it would also be recomputed on every streamed token of every turn, and the
    /// readers that need this (the sidebar mark, the Dock badge, the menu bar count) are not in a
    /// position to walk anything: see `AppModel.waitingWorkspaceIDs`.
    var isAwaitingPermission: Bool { storedIsAwaitingPermission }
    private var storedIsAwaitingPermission = false
    private(set) var isLoaded = false

    /// How full the model's context window is, as of the newest row that said anything about it.
    ///
    /// Stored for exactly the reason `isAwaitingPermission` is stored, and the composer is exactly
    /// the reader that argument was written for. It used to be derived in the composer's own body
    /// from `rows`, which is observed, so every row appended during a turn invalidated the whole
    /// composer subtree: the box, the chips, the footer and its four menus, once per streamed
    /// block. And the walk itself could not stop early when there was no answer to find, because
    /// the limit only ever arrives on the line that closes a turn, so a session that had never
    /// finished one walked the entire transcript on every pass to return nil. Keeping the answer
    /// removes the walk and the dependency together. See `ContextWindowUsage.updated`.
    private(set) var contextUsage: ContextWindowUsage?

    /// Text and thinking arriving live, before the completed block is persisted.
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    private(set) var streamingToolName: String?
    private(set) var thinkingTokens = 0
    private(set) var statusLabel: String?

    /// The turn waiting out an outage, while it is waiting.
    ///
    /// Live state rather than rows, for the reason on `AgentRetry`: ten announcements about one
    /// stuck request are one fact, and nine tenths of it is stale by the time the tenth arrives.
    /// Cleared the moment anything else arrives, which is what makes the handover to the error row
    /// clean: a turn that runs out of attempts ends with its failure drawn once, not with a
    /// waiting row still sitting above it saying it is about to try again.
    private(set) var retryRun: RetryRun?

    /// Turns that waited and then got through, keyed by the `seq` of the result row that closed
    /// them, so the footer can account for the minutes.
    ///
    /// **This is what happens to the waiting row when it succeeds.** It does not simply vanish,
    /// because then nothing explains why a turn took three minutes; and it does not stay as it
    /// was, because a warning plate over a turn that is fine is a lie. It collapses to one quiet
    /// sentence under the turn, in the footer's own ink. In memory only: a transcript reopened
    /// tomorrow has the duration and no explanation, which is where it was before any of this.
    private(set) var recoveredRuns: [Int: RetryRun] = [:]

    /// The subagents this turn has spawned, in the order it spawned them.
    ///
    /// One roster per session rather than per workspace, because a workspace with four chats runs
    /// four turns and the sidebar draws the active chat's. It is deliberately not stored: see
    /// `SubagentRoster` for the argument, which is that the longest one of these is meant to live
    /// is a single turn and the CLI's own record of it is already on disk.
    private(set) var subagents = SubagentRoster() {
        didSet { if let id = workspace?.id { app.noteSubagentsChanged(workspaceID: id) } }
    }

    var draft = ""

    /// What has been asked for on this session and has not gone yet, oldest first.
    ///
    /// Read by the transcript to draw the pending bubbles and by the drain to decide what goes
    /// next. It mirrors the `deliveries` table rather than being the queue itself: the table is
    /// the queue, because a message somebody typed has to survive quitting Bloom. See `Delivery`.
    private(set) var pendingDeliveries: [Delivery] = []

    /// The sentence that is on its way to the agent and has no `messages` row yet.
    ///
    /// **This is the instant echo, and it exists because pressing Return drew nothing at all.**
    /// The runner writes the user row as part of `send`, and the transcript only ever read rows
    /// back when an agent event arrived, so the owner's own message did not appear until the
    /// answer began. Every call to `appendLatestMessages` sat inside `handle(_:)`, and the two
    /// events that arrive before the model says anything, `initialized` and `status`, are not
    /// among the cases that call it: the earliest his own sentence could reach the screen was the
    /// agent's first word about it. That was true before the queue landed and is not a regression
    /// of it.
    ///
    /// So the moment something is submitted with nothing holding the queue, it is held here and
    /// drawn as an ordinary user bubble, in `UserTurnRowView`, with the same text and the same
    /// numbers the stored row will use. It is cleared by the user row arriving, in `absorb`, so
    /// the drawing is replaced by an identical drawing in one pass and nothing moves. A message
    /// that is NOT free to go is not held here: it stays in `pendingDeliveries` and is drawn as
    /// the pending bubble, which says why it is waiting. `Delivery.goesImmediately` is the one
    /// place that decision is taken, and the drain asks the same function.
    private(set) var sending: Delivery?

    /// The queue as the transcript draws it: everything still waiting, and never the one already
    /// drawn as a sent bubble. The drain reads `pendingDeliveries`, which is the table, because
    /// what may be delivered is not a question about what is on screen.
    var waitingDeliveries: [Delivery] {
        guard let sending else { return pendingDeliveries }
        return pendingDeliveries.filter { $0.id != sending.id }
    }

    /// Whether this chat has nothing on screen at all, counting a sentence on its way out and a
    /// sentence waiting in the queue as things on screen. An empty state drawn over either of
    /// them is an empty state drawn over the one thing the owner is looking for.
    var hasNothingToShow: Bool {
        rows.isEmpty && sending == nil && pendingDeliveries.isEmpty
    }

    /// Whether the turn that is ending was ended by a person pressing Stop.
    ///
    /// Stop is not "next, please". Somebody who stops an agent is stepping in, and firing the
    /// message they queued four minutes ago into the silence they just made is the opposite of
    /// what they asked for. A cancelled turn still emits its own result (see `stop()`), so the
    /// drain hanging off that result has to be able to tell the two endings apart. Cleared when a
    /// turn starts, so it never outlives the turn it describes.
    private var wasStoppedByHand = false

    /// Whether the chat above this one has already been told that this turn ended.
    ///
    /// A turn has two endings that report, `.error` and `.result`, and they are not alternatives:
    /// `AgentRunner` yields `.error(.storage(...))` when a transcript write fails without ending
    /// the turn, so the failure sentence went out and then the turn's own result went out behind
    /// it. An orchestrator told twice that one agent stopped picks the work back up twice, on the
    /// first sentence and then again on a second that says the same thing. Cleared where a turn
    /// begins, so it never silences the next one.
    private var hasReportedTurnEnded = false

    /// Bumped whenever something outside the list asks it to go back to the newest row. A counter
    /// rather than a flag, so two requests in a row are two requests, and the list has nothing to
    /// clear afterwards. See `jumpToLiveEnd`.
    private(set) var liveEndRequests = 0

    /// Bumped when something outside the composer has put words in the draft that the owner is
    /// meant to carry on writing. A counter for `liveEndRequests`'s reason: two requests in a row
    /// are two requests, and the composer has nothing to clear afterwards.
    private(set) var composerFocusRequests = 0

    private var runner: (any SessionRunner)?
    private var pumpTask: Task<Void, Never>?
    /// Preferences are captured when a runner is created. Comparing them at delivery time avoids
    /// reusing a process after the picker changed, even when persistence is still catching up.
    private var runnerPreferences: RunnerPreferences?
    private var indexByRefID: [String: Int] = [:]
    /// The one read of this session's history, held so that it happens once however many callers
    /// ask for it.
    ///
    /// Two of them do, and both arrive before it has finished: `WorkspaceModel.transcript(for:)`
    /// reads a model eagerly the moment it builds one, and `TranscriptListView`'s own task reads it
    /// again when the pane draws. `isLoaded` cannot keep them apart, since it is only true on the
    /// last line of the read. `SingleFlight` is named after, and documents, the transcript that
    /// would not draw when the two of them ran the read at once.
    private let loader = SingleFlight()
    /// The newest stored message this model has ingested, whether or not that message became a
    /// row. Tool results fold into their tool-use row, so the rendered rows cannot answer this
    /// without both walking the whole transcript and still sometimes returning an older sequence.
    /// Outside observation because it is only a database cursor and nothing draws it.
    @ObservationIgnored private var highestSeenMessageSeq = -1
    /// When the current turn was handed to the runner, so a session row written before that can be
    /// recognised as belonging to the previous turn.
    private var turnStartedAt: Date?

    init(session: Session, workspace: Workspace, app: AppModel) {
        self.session = session
        self.workspace = workspace
        self.cwd = workspace.path
        self.app = app
    }

    /// The conversation that belongs to Bloom rather than to a workspace.
    ///
    /// A second initialiser rather than an optional argument on the one above, because the two
    /// disagree about what `cwd` is and a caller passing nil to the first would have had to know
    /// to pass a directory as well. See `AskConversation`.
    init(askSession session: Session, directory: String, app: AppModel) {
        self.session = session
        self.workspace = nil
        self.cwd = directory
        self.app = app
    }

    private var store: Store? { app.store }

    // MARK: - Loading

    func load() async {
        guard let store, !isLoaded else {
            SwitchTrace.mark("transcript.reused", workspace: workspace?.id)
            SwitchTrace.markOnScreen("transcript.reused", workspace: workspace?.id)
            return
        }
        // Whichever of the two callers gets here first does the reading, and the other waits on it.
        // The guard above cannot tell them apart, because neither of them is reusing anything: they
        // are both asking for the same session's history at the same moment.
        await loader.run { [self] in await read(from: store) }
    }

    /// The read itself, reached only through `loader`.
    ///
    /// The rows are built into a list off to one side and put on the model in one assignment at the
    /// end, rather than the model's own list being emptied and then filled. There is an await in
    /// the middle of this and there will probably be another one day, and a half built row list
    /// must never be observable: a `ForEach` handed rows whose identifiers repeat lays them out in
    /// whatever order it pleases, and that is what left an answer undrawn until the scroller was
    /// dragged.
    private func read(from store: Store) async {
        SwitchTrace.mark("transcript.read.start", workspace: workspace?.id)
        let messages = (try? await store.messages(sessionID: session.id)) ?? []
        SwitchTrace.mark("transcript.read.done", workspace: workspace?.id)
        // Read once for the whole session rather than per row: a transcript can hold thousands of
        // rows and at most a handful of them are questions.
        let decisions = (try? await store.permissionAskDecisions(sessionID: session.id)) ?? [:]

        // Off the main actor, and not for tidiness. The fold below is the one place in the app
        // that JSON-parses a whole session in one go: `ParentProbe.parentToolUseID` materialises
        // every message's payload to read one top level key, `ToolResultSummary.decode` does it
        // again for every tool result, which is the largest payload in the file, and
        // `PermissionAsk.decode` a third time for every question. Measured with `--switch-probe`
        // on a release build against the 1,306 message workspace: 35ms of main thread between
        // `transcript.read.start` and `transcript.rows.built`, in the middle of the wait between
        // clicking a workspace in the sidebar and seeing it.
        //
        // It is safe to move because it was already written to be moved. `absorb` is static and
        // folds into a list handed to it rather than into the model's own, which is what the
        // paragraph at the head of this function is about, so nothing observable exists until the
        // assignment below.
        let built = await Task.detached(priority: .userInitiated) {
            var rows: [TranscriptRow] = []
            var index: [String: Int] = [:]
            var highestMessageSeq = -1
            for message in messages {
                highestMessageSeq = max(highestMessageSeq, message.seq)
                Self.absorb(message, decisions: decisions, into: &rows, indexByRefID: &index)
            }
            return (rows: rows, index: index, highestMessageSeq: highestMessageSeq)
        }.value

        rows = built.rows
        indexByRefID = built.index
        highestSeenMessageSeq = built.highestMessageSeq

        // The parsing every row of the window is about to want, done now and off this thread. See
        // `TranscriptPrime`, which is where the whole argument for it is. Nothing cancels it: it
        // is one window of a session that has just been asked for, at `.utility`, and a handle
        // nobody would ever call `cancel` on is bookkeeping.
        let unread = firstUnreadSeq
        Task.detached(priority: .utility) { [rows = built.rows, worktree = cwd] in
            await TranscriptPrime.run(rows: rows, worktree: worktree, unreadSeq: unread)
        }

        // Stays on the main actor, and can afford to: it walks backwards and stops as soon as it
        // has both numbers, which is within a few rows of the end whatever the session's length.
        //
        // The one place the whole list is walked, because it is also the one place there is a
        // whole list to walk. Everything after this folds in what arrived. Nothing is held from
        // before: this is a session being read from the start.
        contextUsage = ContextWindowUsage.latest(in: built.rows)
        SwitchTrace.mark("transcript.rows.built", workspace: workspace?.id)
        SwitchTrace.markOnScreen("transcript.rows.built", workspace: workspace?.id)

        draft = (try? await store.draft(sessionID: session.id)) ?? ""
        // Read, and deliberately not drained. A message queued before the last quit must not
        // start a paid turn on a Mac nobody is sitting at, so it is shown as pending and goes with
        // the owner's next message. See `DeliveryHold.none`.
        await refreshQueue()
        isLoaded = true
    }

    /// Folds a stored message into the row list, pairing tool results onto their tool call.
    ///
    /// Handed the list and the reference index it is folding into rather than reaching for the
    /// model's own, so that the same rule can build a whole session's rows somewhere nothing can
    /// see them. See `read(from:)` for why that matters.
    /// Nonisolated, so `read(from:)` can run the whole session's worth of it off the main actor.
    /// It touches nothing but its arguments, which is what made the move a two line change.
    nonisolated private static func absorb(
        _ message: Message,
        decisions: [String: String],
        into rows: inout [TranscriptRow],
        indexByRefID: inout [String: Int]
    ) {
        if message.kind == .toolResult, let refID = message.refID,
           let index = indexByRefID[refID] {
            rows[index].resultPayload = message.payload
            let summary = ToolResultSummary.decode(message.payload)
            rows[index].isError = summary.isError
            rows[index].refusal = summary.refusal
            rows[index].refusalReason = summary.reason
            if let duration = message.durationMS { rows[index].durationMS = duration }
            return
        }

        var row = TranscriptRow(message: message)
        row.parentToolUseID = ParentProbe.parentToolUseID(message.payload)
        if message.kind == .permissionAsk,
           let ask = PermissionAsk.decode(payload: message.payload) {
            row.permissionDecision = decisions[ask.requestID]
        }
        rows.append(row)
        if message.kind == .toolUse, let refID = message.refID {
            indexByRefID[refID] = rows.count - 1
        }
    }

    /// The same fold, straight onto the model, for the rows that arrive while the session is open.
    private func absorb(_ message: Message, decisions: [String: String] = [:]) {
        Self.absorb(message, decisions: decisions, into: &rows, indexByRefID: &indexByRefID)
        // The stored row has arrived, so the bubble drawn from the queue is now the same sentence
        // drawn twice. Retired here rather than after the send returns, because the pump can read
        // the row first: only one turn is ever in flight, so a user row landing while something is
        // sending is that sentence. See `sending`.
        if message.kind == .user { sending = nil }
    }

    /// The turn somebody stopped, named by the `seq` of the row that closed it.
    ///
    /// A stop is a fact about the chat rather than about a row: `SessionState.cancelled` says the
    /// last turn was ended by hand, and the state leaves `cancelled` the moment another turn
    /// starts, so the stop can only ever be about the last one. Derived here rather than written
    /// into `messages` for the reason `WorkspaceEvent`'s header sets out: a row Bloom writes about
    /// a turn would be read back by whatever assembles a prompt, and a note to the person is not
    /// something the agent should be told. Derived also means it is simply gone when the next turn
    /// starts, instead of being a stale second line left behind for ever.
    ///
    /// Nil when the stop left no result row at all, which `StoppedTurn` explains.
    var stoppedTurnSeq: Int? {
        guard session.state == .cancelled else { return nil }
        // Lazily, so a session of thousands of rows is not copied into an array of kinds to answer
        // a question the last two or three rows settle.
        guard let index = StoppedTurn.closingRow(in: rows.lazy.map(\.kind)) else { return nil }
        return rows[index].seq
    }

    // MARK: - Unread

    var firstUnreadSeq: Int? {
        rows.first { $0.seq > session.lastReadSeq }?.seq
    }

    func markAllRead() async {
        guard let store, let last = rows.last?.seq, last != session.lastReadSeq else { return }
        session.lastReadSeq = last
        try? await store.updateLastReadSeq(sessionID: session.id, seq: last)
    }

    /// Pulls the session row back from the store. Anything the runner owns (the agent session
    /// id, the state, the counters) only ever travels in this direction.
    func refreshSession() async {
        guard let store, let fresh = try? await store.session(id: session.id) else { return }
        session = fresh
        // The runner owns the state column, and it writes a terminal state from paths that do not
        // always reach the UI as an event. Trusting the row here is what keeps the composer from
        // spinning against an agent that is already gone. A row last written before the current
        // turn started still describes the previous one, so it says nothing about this turn.
        let isStale = turnStartedAt.map { fresh.updatedAt < $0 } ?? false
        if !isStale, fresh.state == .failed || fresh.state == .cancelled {
            setRunning(false)
            statusLabel = nil
        }
    }

    /// The pickers in the composer write through here so they touch only their own columns.
    func updatePreferences(
        title: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        agentKind: AgentKind? = nil
    ) async {
        guard let store else { return }
        try? await store.updateSessionPreferences(
            id: session.id,
            title: title,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            agentKind: agentKind
        )
        await refreshSession()
    }

    /// Asks the list to go back to the newest row.
    ///
    /// The live end rather than a row, and that is the whole of what changed here. This used to
    /// name `firstUnreadSeq` and scroll to it, which asks the list for a position inside its lazy
    /// stack, and a stack that is drawing the end of a long session does not necessarily hold that
    /// row yet. An edge needs no identity and is always there.
    func jumpToLiveEnd() {
        liveEndRequests += 1
    }

    // MARK: - Sending

    /// Everything anybody says to this chat, and the only way in.
    ///
    /// **One ordered queue, because there used to be two paths and they raced.** The prompt typed
    /// in the create window waited inside the setup task; anything typed into the composer during
    /// that minute went straight to the runner, since nothing marks a session busy while its
    /// worktree is being built. The owner opened a workspace asking for one thing, typed a second
    /// thing while the script ran, and watched the second one answered first. Nothing about that
    /// was fixable by hurrying one of the two paths along: whichever continuation the scheduler
    /// reached first won, so the fix is that there is one path and it has an order.
    ///
    /// So this never sends. It joins the queue and then asks the queue to move, which is also what
    /// makes the invariant cheap to state: what is delivered is delivered in the order it was
    /// asked for, whatever asked for it. See `Delivery`.
    ///
    /// **It also draws the sentence before it awaits anything**, which is the whole of the instant
    /// echo. Enqueueing is two round trips to a SQLite actor that a diff refresh or an archive can
    /// be sitting in front of, and handing the line to the runner is a process launch behind that.
    /// None of it is work the owner should watch an empty transcript through, so the message is on
    /// screen from the frame the key went down, in the state `Delivery.goesImmediately` says it is
    /// in: as a sent bubble if nothing is holding the queue, as a pending one if something is. See
    /// `sending`.
    func submit(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let store else { return }

        draft = ""

        // Built here rather than inside the enqueue, so the row that goes in the table and the
        // bubble that goes on screen are one object with one id. Drawn twice under two ids is the
        // duplicate that would appear the moment the queue was read back.
        let delivery = Delivery(targetSessionID: session.id, body: body)
        if Delivery.goesImmediately(behind: pendingDeliveries, hold: deliveryHold) {
            sending = delivery
        } else {
            pendingDeliveries.append(delivery)
        }

        // And the list is taken to it, on the same frame, for the same reason the bubble is drawn
        // before anything is awaited: what somebody just asked for should be the thing they are
        // looking at.
        //
        // The bug this closes was Merge. The button composes a turn and sends it down this path,
        // the transcript did not follow, and the request landed below the fold with the jump pill
        // floating over the top of it: the one thing the owner had just triggered was the one
        // thing off screen. It was never only Merge. Create pull request, Push, the continuation
        // after a merge, a review sent with comments and a reply typed into a banner all arrive
        // here, and a message typed into the composer while the reader was scrolled up did the
        // same. One queue in, one rule about where the list sits.
        //
        // `jumpToLiveEnd` rather than a scroll of its own: it is the jump pill's own request, so
        // this reuses the display-link glide in `TranscriptListView.goToLiveEnd`, which already
        // asks `TranscriptMotion` whether Reduce Motion is on and jumps instead when it is.
        jumpToLiveEnd()

        try? await store.saveDraft(sessionID: session.id, body: "")

        do {
            _ = try await store.enqueueDelivery(delivery)
        } catch {
            // The bubble was drawn on the promise that this would be queued. It was not, so the
            // promise is taken back rather than left on screen next to a message that is never
            // going anywhere.
            sending = nil
            pendingDeliveries.removeAll { $0.id == delivery.id }
            Log.composer.error(
                "the message could not be queued: \(error.readableMessage, privacy: .public)"
            )
            app.alert = BloomAlert(
                title: "Could not queue the message",
                message: TranscriptStanding.complaint(about: error)
            )
            return
        }

        // Not from `drain`, and not before the enqueue. The owner saying something is the moment a
        // queue held over from a relaunch, or paused by a Stop, is meant to move again, and it
        // moves from the front rather than from what was just typed.
        wasStoppedByHand = false
        await drain()
    }

    /// Why the queue in front of this chat is not moving, which is both the drain's condition and
    /// the sentence the first pending bubble carries. See `DeliveryHold`.
    ///
    /// The setup half is read off the workspace's own model rather than mirrored here. Only that
    /// model runs the script, and a second copy of "is setup running" is a second thing to get
    /// wrong: the transcript already spent a release drawing "setup has not run yet" over output
    /// the script had just printed, for exactly that reason.
    var deliveryHold: DeliveryHold {
        // A chat with no worktree has no setup script to be waiting on, so both halves are
        // false and the hold can only ever be a running turn or an open question.
        let model = workspace.flatMap { app.existingModel(for: $0.id) }
        return DeliveryHold.of(
            isRunningSetup: model?.isRunningSetup ?? false,
            isTurnRunning: isRunning,
            isAwaitingQuestion: isAwaitingPermission
        )
    }

    /// Hands the front of the queue to the agent, if anything is allowed to go.
    ///
    /// One at a time. The next one goes when this turn ends, which is what "never mid-turn" means
    /// on both backends and what keeps the queue an ordered thing rather than a burst.
    ///
    /// Called from the three moments a queue is meant to move and from nowhere else: the setup
    /// script finishing, a turn ending of its own accord, and the owner submitting. Not on launch,
    /// and not after a Stop. Both of those would spend the owner's money on a turn nobody asked
    /// for at that moment, and both are covered by the queue simply sitting there, visibly, until
    /// somebody says something.
    func drain() async {
        guard let store else { return }
        await refreshQueue()
        guard let next = Delivery.next(from: pendingDeliveries, hold: deliveryHold) else { return }

        // Drawn as said from here, whichever moment the queue is moving in: the owner submitting
        // (where `submit` has already done it, to the same id), a setup script finishing, or the
        // turn in front of it ending. Before the retire below, so there is no frame on which the
        // sentence has left the queue and has not yet become a bubble. See `sending`.
        sending = next

        // Retired before it is handed over, rather than after. The pending bubble and the real one
        // are two drawings of the same sentence, and a delivery that is still pending while its
        // turn is starting is drawn twice. `restoreDelivery` below is the one path back.
        try? await store.markDelivered(id: next.id)
        await refreshQueue()

        await deliver(next)
    }

    /// Whether this delivery is at the front of an idle queue and can be attempted now.
    func canRetry(_ delivery: Delivery) -> Bool {
        Delivery.next(from: pendingDeliveries, hold: deliveryHold)?.id == delivery.id
    }

    /// Attempts the front of the queue again without changing its order or duplicating its text.
    func retryPending() async {
        wasStoppedByHand = false
        await drain()
    }

    /// The queued message the owner has asked to delete, and the reason the sheet is up.
    ///
    /// Here rather than in the row that draws it because the question outlives the row: the drain
    /// can retire that delivery while the sheet is open, at which point the row goes and the sheet
    /// has to be told. A `@State` inside `PendingTurnRowView` would be torn down with the row and
    /// take the dialog with it silently, which is the one outcome the race must not have.
    var discarding: Delivery?

    /// Asks before deleting, rather than deleting.
    ///
    /// The words are `PendingMessageDiscard`'s, including the promise about where the sentence
    /// ends up, so the dialog cannot promise something this object then does not do.
    func askToDiscard(_ delivery: Delivery) {
        guard PendingMessageDiscard.canDiscard(delivery) else { return }
        discarding = delivery
    }

    /// Takes one back out of the queue, because whoever asked for it changed their mind.
    ///
    /// The recovery is worked out here rather than when the question was asked, because the
    /// composer is live behind the sheet: what the box holds when the answer comes is what decides
    /// whether the sentence can go back into it.
    func confirmDiscard(_ delivery: Delivery) async {
        discarding = nil
        guard let store else { return }
        let recovery = PendingMessageDiscard.recovery(of: delivery, composerDraft: draft)
        let removed = (try? await store.cancelDelivery(id: delivery.id)) ?? false
        await refreshQueue()

        // It went while the question was on screen. The delete loses that race on purpose: see
        // `PendingMessageDiscard.alreadySentSentence`.
        guard removed else {
            app.notice = BloomNotice(message: PendingMessageDiscard.alreadySentSentence)
            return
        }

        if case .toComposer(let text) = recovery {
            draft = text
            await saveDraft()
        }
    }

    /// Takes one back out of the queue and into the composer, to be changed before it goes.
    ///
    /// No confirmation, because nothing is lost: the words end up in the box the owner is looking
    /// at. `Store.cancelDelivery` is the same way out Delete uses, so the drain cannot fire on a
    /// message this has already handed back, and the same lost race is possible and says so.
    ///
    /// The join is worked out after the row is gone rather than before, so the words go in front
    /// of whatever the box holds by then rather than in front of what it held a round trip ago.
    func editPending(_ delivery: Delivery) async {
        guard PendingMessageEdit.canEdit(delivery), let store else { return }
        let removed = (try? await store.cancelDelivery(id: delivery.id)) ?? false
        await refreshQueue()

        guard removed else {
            app.notice = BloomNotice(message: PendingMessageEdit.alreadySentSentence)
            return
        }

        draft = PendingMessageEdit.draft(taking: delivery, into: draft)
        // Both before the write, the way `submit` draws and jumps before it awaits anything: the
        // box the words landed in is where the owner should be on that frame, not a round trip
        // later.
        composerFocusRequests += 1
        jumpToLiveEnd()
        await saveDraft()
    }

    /// Closes the question when the message it is about is no longer waiting.
    ///
    /// Called from `refreshQueue`, which is the one place this object learns the queue has moved.
    /// The owner is told, because a dialog that vanishes on its own reads as a bug and because
    /// what happened underneath it is exactly the thing they were trying to prevent.
    private func dropDiscardIfDelivered() {
        guard let discarding else { return }
        guard !pendingDeliveries.contains(where: { $0.id == discarding.id }) else { return }
        self.discarding = nil
        app.notice = BloomNotice(message: PendingMessageDiscard.alreadySentSentence)
    }

    /// Re-reads the queue from the table. Public because the moment a workspace's opening prompt
    /// is enqueued is outside this object, and the bubble has to be on screen from that frame.
    func refreshQueue() async {
        guard let store else { return }
        pendingDeliveries = (try? await store.pendingDeliveries(sessionID: session.id)) ?? []
        dropDiscardIfDelivered()
    }

    /// The one place a turn starts, reached only from `drain`.
    private func deliver(_ delivery: Delivery) async {
        // A bare `return` used to stand here, and the sentence went nowhere: `drain` has already
        // retired this delivery from the queue and drawn it as sent, so a quiet return leaves a
        // bubble claiming to have been said to an agent that was never built. It takes a database
        // that never opened, so it is close to impossible, and a message of the owner's
        // disappearing without a word is not a thing to leave resting on that.
        guard let runner = ensureRunner() else {
            await abandon(delivery, saying: "Bloom could not open an agent for this chat.")
            return
        }
        turnStartedAt = Date()
        wasStoppedByHand = false
        hasReportedTurnEnded = false
        // **The clearing rule.** The last turn's subagents go here, at the one place a turn
        // starts, and nowhere else. Clearing them when they finish is the option that reads well
        // in a screenshot and badly in use: three rows leaving one by one take everything below
        // them up the pane while you are still reading the third. Clearing them here means a
        // finished subagent keeps its place, with its tick or its cross and what it answered, for
        // as long as the turn it belongs to is the last thing that happened.
        subagents.turnStarted()
        setRunning(true)
        statusLabel = "Starting"

        do {
            // `sent` rather than `body`, and the payload beside it. They are the same string for
            // anything the owner typed and two different strings for a crew message: what the
            // model is handed is the envelope, and what the transcript draws is the words. See
            // `Delivery.sent` and `SessionRunner.send(_:recording:)`.
            try await runner.send(delivery.sent, recording: delivery.crewPayload)
            // The runner writes the user row as part of the send, and until this line nothing read
            // it back: the transcript only pulled rows on an agent event, so the owner's own
            // message did not appear until the answer did. Reading it here is what retires the
            // echo, and `absorb` is what clears `sending` when the row lands, so the two drawings
            // of the sentence swap inside one synchronous pass and nothing on screen moves.
            await appendLatestMessages()
        } catch {
            setRunning(false)
            statusLabel = nil
            await abandon(delivery, saying: error.readableMessage)
        }
    }

    /// A turn that could not start, said out loud and put back in the queue.
    ///
    /// **The row is the part that was missing, and silence is what this bug cost.** An alert says
    /// it once, to whoever is looking at that moment, and then it is gone; the transcript is where
    /// somebody goes a minute later to work out what happened, and it held nothing at all. So the
    /// account of it goes in as an `.error` row, drawn by `AgentErrorRowView` beside every other
    /// way a turn can fail. A modal alert would hide that recovery UI and require dismissal before
    /// the person can act, so it is reserved for the exceptional case where no row can be stored.
    ///
    /// The delivery goes back to being pending rather than reading as sent. It used to go back
    /// into the composer, which was right when the composer was the only place an unsent prompt
    /// could live and is wrong now that there is a queue: a failed start with three messages
    /// behind it would have pasted one of them over the top of whatever the user was typing, and
    /// lost its place in the order. An unsent prompt is often minutes of thought and this app
    /// holds the only copy of it; it stays where it can be read, cancelled and sent again.
    private func abandon(_ delivery: Delivery, saying complaint: String) async {
        // Nothing was said after all, so the bubble that said it was going stops claiming so.
        sending = nil

        Log.composer.error(
            "the agent would not start, so the prompt stayed in the queue: \(complaint, privacy: .public)"
        )

        // Everything durable needs the database, and one of the two ways in here is the database
        // never having opened. Only that path needs an alert because it has nowhere to put an
        // inline explanation or a message that can be retried.
        guard let store else {
            app.alert = BloomAlert(title: "Could not start the agent", message: complaint)
            return
        }

        try? await store.restoreDelivery(id: delivery.id)
        await refreshQueue()

        let row = AgentError.notStarted(message: complaint)
        _ = try? await store.appendNext(sessionID: session.id, kind: .error, payload: row.raw)
        await appendLatestMessages()
    }

    func saveDraft() async {
        guard let store else { return }
        try? await store.saveDraft(sessionID: session.id, body: draft)
    }

    /// The one place `isRunning` moves.
    ///
    /// Seven call sites set it, and every one of them also has to reach `AppModel`, because the
    /// sidebar's status strip, Home's summary line, the menu bar item, the Dock badge and the
    /// sleep assertion are all answers to "is anything running" and none of them can see this
    /// object. `AppModel.runningWorkspaceIDs` explains why they cannot simply read it: the model
    /// dictionary those readers would have to walk is outside observation on purpose.
    ///
    /// Idempotent, so a path that stops an already stopped turn writes nothing and invalidates
    /// nobody.
    private func setRunning(_ value: Bool) {
        // A turn that has ended cannot still be waiting on a question, and there are six places
        // that end one: a stale terminal state read back from the row, a send that threw, Stop,
        // quit, the agent dying, and the result line. Clearing it here rather than at all six is
        // the same argument that made this method exist, and it happens before the guard because
        // the two flags can disagree: a turn stopped while blocked is already not running.
        if !value { setAwaitingPermission(false) }

        guard storedIsRunning != value else { return }
        storedIsRunning = value
        app.noteAgentTurnsChanged()
    }

    /// The one place `isAwaitingPermission` moves, for the same reasons `setRunning` is the one
    /// place `isRunning` does.
    ///
    /// Idempotent, so answering the second of two questions writes nothing.
    private func setAwaitingPermission(_ value: Bool) {
        guard storedIsAwaitingPermission != value else { return }
        storedIsAwaitingPermission = value
        app.noteAgentTurnsChanged()
    }

    /// Recompute from the questions actually outstanding. Called wherever one is added or settled,
    /// so a turn that asked three things goes back to running only when the last is answered.
    private func refreshAwaitingPermission() {
        setAwaitingPermission(!pendingPermissionAsks.isEmpty)
    }

    /// The UI stops looking busy right away, but the pump is deliberately left running: a cancelled
    /// turn still emits its own result, and that event is what writes the final state back into the
    /// session row. Tearing the pump down here used to strand the session until the next launch.
    func stop() {
        // Remembered so the result this cancellation is about to produce does not look like a turn
        // that finished, and therefore does not let the queue move. See `wasStoppedByHand`.
        wasStoppedByHand = true
        runner?.cancelNow()
        setRunning(false)
        statusLabel = nil
        clearStreaming()
    }

    /// The chat is going away for good, so the process goes with it.
    ///
    /// `stop()` above is deliberately not this. Stop leaves a Codex chat's `app-server` running,
    /// because that is what makes the next message resume in the same process with the grants the
    /// person already gave; closing, archiving and quitting mean the opposite, and used to reach
    /// the same method. So a Codex chat's server was never signalled by anything, which is the
    /// orphaned-children bug this app already fixed once on the Claude Code side.
    func terminateNow() {
        stop()
        runner?.terminateNow()
    }

    /// The session itself is going away, so the pump goes with it. The event stream never ends on
    /// its own, and a pump left iterating one holds its runner alive for the rest of the launch.
    func teardown() {
        terminateNow()
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Quit path. Signals the agent and waits, briefly, for it to actually be gone, because macOS
    /// hands our children to launchd rather than killing them.
    ///
    /// The wait is on the process, not on the turn. Polling "is a turn running" is what let this
    /// return happily on a Codex chat whose server was still very much alive: the interrupt landed,
    /// the turn closed, and nothing had ever been signalled.
    func shutdown() async {
        guard let runner else { return }
        terminateNow()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3.5))
        while ContinuousClock.now < deadline {
            let alive = await runner.isProcessAlive
            if !alive { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Starts the runner and the event pump on first use. The pump is rebuilt whenever it is
    /// missing, so no path can leave a live runner with nothing reading its events.
    ///
    /// Which runner is the chat's own answer, read off `session.agentKind`, and it is read once:
    /// a chat that has started is on the backend it started on for as long as it lives. Changing
    /// the picker on a chat that has already spoken forks a new chat rather than turning this one
    /// into something else, because its rows, its thread and its context all belong to the backend
    /// that made them. See `ComposerBackendChange` and docs/CODEX.md.
    /// Nil when the database never opened, rather than a crash.
    ///
    /// It was `app.store!`, the one force unwrap in this file where every other reference goes
    /// through `store` and a `guard let`. It was safe only because its single caller guards four
    /// lines up, which is a fact about `deliver` rather than about this method. `app.store` stays
    /// nil forever if the open in `AppModel.bootstrap` throws while `isLoaded` is set true, so a
    /// second caller of this would take the app down. There is no reason for the guarantee to be
    /// somewhere other than here.
    private func ensureRunner() -> (any SessionRunner)? {
        guard let store else { return nil }
        let preferences = RunnerPreferences(session: session)
        if runner != nil, runnerPreferences != preferences {
            runner?.terminateNow()
            pumpTask?.cancel()
            pumpTask = nil
            runner = nil
            runnerPreferences = nil
        }
        // Two registrations, because there are two identities. A chat in a worktree gets a token
        // minted for that workspace and the role its origin says; Ask Bloom gets the owner's own,
        // which is the same door the owner's terminal comes in through and the reason every owner
        // tool works here without one of them being written twice.
        let bridge = workspace.map { app.bridge?.register(session: session, workspace: $0) }
            ?? app.bridge?.register(askSession: session)
        let runner = self.runner ?? Self.makeRunner(
            session: session,
            workspacePath: cwd,
            store: store,
            bridge: bridge
        )
        self.runner = runner
        runnerPreferences = preferences
        if pumpTask == nil { startPump(on: runner) }
        return runner
    }

    /// The one place a backend becomes a process. Static and taking only values, so which runner a
    /// session gets can be asserted on without a workspace, a store or a view.
    ///
    /// It is also the one place the workspace bridge is registered, and that is not a coincidence:
    /// the bridge is per process, so it belongs wherever the process is decided. A runner built
    /// anywhere else would be a second CLI on the same session row, which is the invariant
    /// `BridgeServer` refuses to touch and the reason nothing on the bridge's side of the socket
    /// may build one.
    static func makeRunner(
        session: Session,
        workspacePath: String,
        store: Store,
        bridge: BridgeHandle? = nil
    ) -> any SessionRunner {
        switch session.agentKind {
        case .codex:
            return CodexRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                bridge: bridge?.attachment
            )
        // Cursor and OpenCode have no runner, and `AgentKind.canRunWorkspaces` is what stops a
        // chat ever being on one. A chat that somehow is falls back to Claude Code rather than
        // refusing to start, because a transcript that cannot be typed into is a worse answer
        // than one running the backend every existing chat already runs.
        case .claudeCode, .cursor, .openCode:
            return AgentRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                mcpConfigPath: bridge?.mcpConfigPath
            )
        }
    }

    private func startPump(on runner: any SessionRunner) {
        pumpTask = Task { [weak self] in
            for await event in runner.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: - Event handling

    /// The event pump's door, opened for one caller: `StreamProbe`.
    ///
    /// **A probe hook in a production type, deliberately, and this is the argument for it.** What
    /// the probe has to measure is what Bloom does with a delta, and the only faithful way to
    /// measure that is to hand this the events a runner hands it. The alternative was a probe that
    /// wrote `streamingText` directly, which measures a property being assigned rather than a turn
    /// arriving, and would go on measuring it after the pump around it had changed. Nothing else
    /// may call this: a runner reaches `handle` through its own pump, and anything else pushing
    /// events into a transcript would be a second writer on state that has exactly one.
    func acceptForProbe(_ event: AgentEvent) async {
        await handle(event)
    }

    private func handle(_ event: AgentEvent) async {
        switch event {
        case .initialized:
            // The runner persists the agent session id itself. Read it back rather than writing
            // our own copy, which would be a second writer racing the runner on the same row.
            await refreshSession()
            statusLabel = "Working"

        case .status(let label):
            // "Requesting" describes the CLI's protocol state, not what the person is waiting
            // for. The model has the request at this point and has not started answering yet.
            statusLabel = label.lowercased() == "requesting"
                ? "Waiting for model"
                : label.capitalizedFirst

        case .retrying(let retry):
            absorb(retry)

        case .thinkingTokens(let total):
            thinkingTokens = total

        case .streamDelta(let delta):
            switch delta {
            case .text(let chunk): buffer.text += chunk
            case .thinking(let chunk): buffer.thinking += chunk
            // Not buffered. It arrives once per tool call rather than per token, and it is what
            // the status line under the tail says, so a delay on it would be visible where a
            // delay on a few characters of prose is not.
            case .toolName(let name): streamingToolName = name
            case .toolInput: break
            case .blockFinished: break
            }
            scheduleStreamFlush()

        case .assistantText, .thinking, .toolUse, .toolResult:
            // Anything at all arriving from the model means the request that was being retried got
            // through. That is the only signal there is: the CLI announces a retry and never
            // announces a recovery, so the recovery is the next event of any kind.
            settleRetryRun()
            clearStreaming()
            await appendLatestMessages()

        case .error(let failure):
            // The agent died without ever producing a result: a model it does not know, expired
            // credentials, a crash. Nothing else will arrive, so the turn ends here or the composer
            // stays locked for the rest of the launch.
            //
            // The waiting row goes without leaving a note. The error row about to be drawn is
            // already the account of this outage, and two surfaces explaining one failure is
            // exactly the clutter the waiting row was written to avoid.
            abandonRetryRun()
            clearStreaming()
            await appendLatestMessages()
            setRunning(false)
            statusLabel = nil
            subagents.turnEnded()
            await refreshSession()
            app.alert = BloomAlert(
                title: "The agent stopped in \(workspaceNow?.name ?? AskConversation.title)",
                message: failure.message.isEmpty ? "It exited without finishing the turn." : failure.message
            )
            // The banner names a workspace and a chat with none has nothing to name. The alert
            // above is already on screen in front of the person who asked, which is where they
            // were: this chat is the one they opened rather than one running in the background.
            if let workspaceNow {
                NotificationService.shared.agentFailed(workspace: workspaceNow, message: failure.message)
            }
            // Both endings report, and this is the one that would otherwise be silent: an
            // orchestrator waiting on a crew member that died looks exactly like one waiting on a
            // crew member that is still thinking. See `Crew.failedSentence`.
            await reportToOrchestrator(
                CrewMessage.failed(name: session.title, reason: failure.message)
            )

        case .result(let result):
            // A turn that recovered leaves its sentence on the row that closes it; one that failed
            // leaves nothing, for the same reason as `.error` above.
            if result.succeeded { settleRetryRun() } else { abandonRetryRun() }
            clearStreaming()
            await appendLatestMessages()
            // After the append, deliberately: the row the sentence hangs under is the result row,
            // and it is not in `rows` until the read above has brought it back from the store.
            fileRecoveredRun()
            setRunning(false)
            statusLabel = nil
            // Anything still breathing was killed with the turn, whatever the last line about it
            // said. The rows stay, marked as stopped; they go when the next turn starts.
            subagents.turnEnded()
            // Token counts, cost and state are all written by the runner as part of handling the
            // same result. Reading them back keeps one writer and avoids double counting.
            await refreshSession()
            await notifyFinished(result: result)
            // A turn that ended by itself is the moment the next queued message is due. A turn the
            // owner stopped is not: they stepped in, and a message they queued minutes ago going
            // out into the silence they just made is the opposite of what Stop is for.
            if !wasStoppedByHand { await drain() }
            // After the drain, and only if nothing moved: a crew member whose orchestrator said
            // something while it was busy has just started the next turn, and telling the
            // orchestrator it has stopped in the same breath would have it act on an answer that
            // is about to be superseded. `drain` is awaited to completion above, `runner.send` and
            // all, and `deliver` sets `isRunning` before that send, so by this line the flag is
            // already describing the turn that has just begun rather than the one that ended.
            if !isRunning {
                await reportToOrchestrator(
                    CrewMessage.stopped(name: session.title, lastMessage: result.summary)
                )
            }

        case .permissionAsk:
            // The row goes in where the call would have been, and the composer stops looking like
            // an agent that is working: it is alive, and it is not going anywhere.
            clearStreaming()
            await appendLatestMessages()
            statusLabel = "Waiting on you"
            refreshAwaitingPermission()
            await refreshSession()
            if let workspaceNow {
                NotificationService.shared.agentNeedsPermission(workspace: workspaceNow)
            }

        case .permissionDecided(let resolution):
            settle(resolution)
            refreshAwaitingPermission()
            if !isAwaitingPermission {
                statusLabel = isRunning ? "Working" : nil
            }
            await refreshSession()

        case .rateLimit(let raw):
            // Both backends converge on this one event, and until now it landed here and stopped.
            // The adapters recognise their own payload and decline the rest, so this one line
            // serves every backend that publishes an allowance and every backend that does not.
            await app.recordQuotas(AgentQuotaAdapters.quotas(fromRateLimitEvent: raw))

        case .subagent(let signal):
            subagents.apply(signal)

        case .hook, .unknown:
            break
        }
    }

    // MARK: - Retries

    /// Folds one announcement into the run it belongs to, starting one if this is the first.
    ///
    /// Only the turn's own retries reach here. A subagent's arrive on its `tool_progress` line,
    /// which is a `.subagent` event, and they live on that subagent's row in `subagents`: they are
    /// a different request with a different backoff, and folding them in here would have the
    /// turn's row counting somebody else's attempts.
    private func absorb(_ retry: AgentRetry) {
        if retryRun != nil {
            retryRun?.absorb(retry)
        } else {
            retryRun = RetryRun(retry)
        }
    }

    /// The wait ended and the work carried on. The run stops being live and is held until the turn
    /// closes, because the row its sentence hangs under is the result row and that does not exist
    /// yet.
    ///
    /// The first run of a turn is the one kept. A turn that hit the outage early, recovered, and
    /// hit it again later is one story about one evening, and the first attempt count is the one
    /// that explains the minutes.
    private func settleRetryRun() {
        guard let run = retryRun else { return }
        if settledRun == nil { settledRun = run }
        retryRun = nil
    }

    /// Files a settled run under the row that closed the turn, once that row is in `rows`.
    private func fileRecoveredRun() {
        guard let run = settledRun, let seq = rows.last?.seq else { return }
        recoveredRuns[seq] = run
        settledRun = nil
    }

    /// A run that has ended in success but whose turn has not closed yet, so the sentence has a
    /// row to hang under when it does.
    private var settledRun: RetryRun?

    /// The turn failed. The run is dropped whole: nothing is said about the waiting, because the
    /// failure is about to say it.
    private func abandonRetryRun() {
        retryRun = nil
        settledRun = nil
    }

    // MARK: - Permission asks

    /// What the project is called, for a permission row that has to say where a rule would apply.
    /// "Always allow ... in Bloom" is a promise about a place, and the place has to be named.
    /// Nil when there is no project behind this chat, which is what stops the card offering a
    /// scope it cannot store. See `PermissionScopeOffer`.
    var projectName: String? {
        guard let workspace else { return nil }
        return app.repo(for: workspace)?.name ?? workspaceNow?.name
    }

    /// The questions this session is holding a turn open for, in the order they arrived.
    var pendingPermissionAsks: [PermissionAsk] {
        rows.compactMap { row in
            guard row.kind == .permissionAsk, row.permissionDecision == nil else { return nil }
            return PermissionAsk.decode(payload: row.payload)
        }
    }

    /// Answer one question. The turn resumes on the other side of this.
    ///
    /// The row is settled here rather than waiting for the event to come back round, so the
    /// buttons stop being pressable the moment one of them is, and a slow store cannot leave two
    /// answers on their way to the same question.
    func answer(requestID: String, decision: PermissionDecision) async {
        settle(PermissionResolution(requestID: requestID, decision: decision.storedName))
        refreshAwaitingPermission()
        await runner?.answer(requestID: requestID, decision: decision)
    }

    /// Mark a question answered on the row that asked it.
    private func settle(_ resolution: PermissionResolution) {
        guard let index = rows.firstIndex(where: {
            $0.kind == .permissionAsk
                && PermissionAsk.decode(payload: $0.payload)?.requestID == resolution.requestID
        }) else { return }

        rows[index].permissionDecision = resolution.decision
        if !resolution.note.isEmpty { rows[index].permissionNote = resolution.note }
    }

    /// Pulls anything the runner has persisted since the last row we hold. The runner is the
    /// single writer, so reading back from the store keeps one ordering and one source of truth.
    private func appendLatestMessages() async {
        guard let store else { return }
        // Nothing is appended to a list the first read is still building. A workspace can be handed
        // a prompt the same moment its model is made, which starts the agent while the history is
        // still on its way in, and the read ends by putting the whole list on the model in one go:
        // a row appended here in the meantime would simply be overwritten.
        await loader.wait()
        let fresh = (
            try? await store.messages(sessionID: session.id, afterSeq: highestSeenMessageSeq)
        ) ?? []
        guard !fresh.isEmpty else { return }
        let appendedFrom = rows.count
        for message in fresh {
            // Before folding, because a tool result changes an old row rather than appending one.
            // The cursor belongs to stored messages, not to their presentation.
            highestSeenMessageSeq = max(highestSeenMessageSeq, message.seq)
            absorb(message)
        }
        // Over what actually arrived, not over the transcript. A tool result folds onto a row that
        // is already there rather than appending, so the slice can be empty, and an empty one
        // leaves the held reading exactly where it was.
        noteContextWindow(in: rows[min(appendedFrom, rows.count)...])
    }

    /// Folds what the newest rows say about the context window into the held reading.
    private func noteContextWindow(in appended: ArraySlice<TranscriptRow>) {
        let usage = ContextWindowUsage.updated(contextUsage, with: appended)
        if usage != contextUsage { contextUsage = usage }
    }

    /// Text and thinking that has arrived and is not on screen yet. See `scheduleStreamFlush`.
    ///
    /// **`@ObservationIgnored`, and it is the difference between a redraw costing one pass over
    /// the transcript and a token costing one.** This is staging. It is written on every delta,
    /// which is tens to hundreds of times a second, and nothing outside `flushStream` has any
    /// business reading it. Observed, it was an edge that anything reading `isStreaming` took, and
    /// `TranscriptListView` was one of those: on the owner's 2,981 row session every single token
    /// walked the whole list's dependencies to find that nothing it draws had moved, and then the
    /// same again fifty milliseconds later when the flush it was staging for actually happened.
    @ObservationIgnored private var buffer = (text: "", thinking: "")
    private var streamFlush: Task<Void, Never>?

    /// How often the live tail is allowed to redraw while an answer arrives.
    ///
    /// **Fifty milliseconds, because the cost of drawing the tail is per REDRAW and the rate the
    /// deltas arrive at is not ours to choose.** Measured with `--stream-probe` on a release
    /// build over a 1,582 row chat: 6.6ms of main thread per delta at sixty deltas a second, which
    /// is 40% of a core burned continuously for as long as an agent is writing, and thirty per
    /// cent of frames late. Most of that is the same work over and over: the whole answer so far
    /// is re-parsed as markdown and re-measured by TextKit on every delta, so a turn that streams
    /// n chunks does O(n²) work to draw one paragraph.
    ///
    /// Coalescing bounds it. Twenty redraws a second is faster than anybody reads and is the same
    /// number whether the backend sends twenty five chunks a second or two hundred, which is the
    /// property that matters: what the app costs while a turn runs stops depending on how chatty
    /// the CLI happens to be.
    ///
    /// Nothing is lost by waiting. Every path that ENDS a stream flushes first, so the last few
    /// characters are on screen before the stored row replaces them.
    private static let streamFlushInterval = Duration.milliseconds(50)

    private func scheduleStreamFlush() {
        guard streamFlush == nil else { return }
        streamFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamFlushInterval)
            guard let self else { return }
            streamFlush = nil
            flushStream()
        }
    }

    /// Puts what has arrived on screen, in one write per property rather than one per delta.
    private func flushStream() {
        if !buffer.text.isEmpty {
            streamingText += buffer.text
            buffer.text = ""
        }
        if !buffer.thinking.isEmpty {
            streamingThinking += buffer.thinking
            buffer.thinking = ""
        }
    }

    private func clearStreaming() {
        streamFlush?.cancel()
        streamFlush = nil
        buffer = ("", "")
        streamingText = ""
        streamingThinking = ""
        streamingToolName = nil
    }

    /// Whether an answer is arriving, as far as anything that draws is concerned.
    ///
    /// **Deliberately blind to `buffer`.** The staging is `@ObservationIgnored`, so a term reading
    /// it would be a term nothing is told about, and this would go stale rather than late. Over
    /// the flushed properties alone it moves at `streamFlushInterval` instead of per token, which
    /// is the whole of what a reader of this wants: twenty answers a second about something that
    /// is only redrawn twenty times a second.
    ///
    /// Nothing appears late because of it. The live tail is drawn on `isRunning || isStreaming`,
    /// and `isRunning` is written synchronously by `deliver` before the send is even awaited, so
    /// the tail is on screen from the frame the turn begins whatever this says. See
    /// `StreamingTailView`.
    var isStreaming: Bool {
        !streamingText.isEmpty || !streamingThinking.isEmpty || streamingToolName != nil
    }

    /// Tells the chat that started this one that it has stopped, and lets that chat's queue move.
    ///
    /// **This is the whole point of the crew design, which is why it hangs off the end of a turn
    /// rather than off a tool an orchestrator has to remember to call.** An orchestrator that has
    /// to ask either polls or forgets, so the end of a crew member's turn is an event Bloom
    /// delivers, carrying what the agent last said rather than a handle to go and fetch it. The
    /// head of `Crew` argues it at length, and the two sentences are written there so that the
    /// promise is one a test can read.
    ///
    /// It enqueues and only then drains, rather than sending. The orchestrator is very often mid
    /// turn at this moment, because a turn of its own is usually what started this agent, and
    /// `DeliveryHold` is what decides: a held report goes when that turn ends, through the same
    /// `drain` every other queued message goes through.
    ///
    /// A chat nobody started returns on the first line, which is nearly every chat in the app.
    ///
    /// At most one report per turn, whichever ending gets here first. See `hasReportedTurnEnded`.
    ///
    /// A `CrewMessage` rather than a sentence, because the two readers want different lengths of
    /// it: the orchestrator is handed the paragraph with the agent's last words and the hint about
    /// tidying up, and the owner's window draws the one line saying the agent stopped. Handing one
    /// string to both is what put an instruction addressed to a model in the owner's own bubble.
    private func reportToOrchestrator(_ message: CrewMessage) async {
        guard let parentID = session.parentSessionID, let store, let workspace else { return }
        guard !hasReportedTurnEnded else { return }

        // Read before the enqueue, and dropped when the chat above has been closed. `session(id:)`
        // answers for an archived row where `sessions(workspaceID:)` and `crew(of:)` do not, and
        // `closeSession` archives a chat while leaving the crew it started running. A report
        // enqueued against a closed chat did not sit there quietly: the drain below built that
        // session a fresh transcript, minted it a bridge token and started a turn in a
        // conversation that is in no tab strip, no session list and no sidebar row. An agent
        // nobody can see, spending money.
        guard let parent = try? await store.session(id: parentID),
              parent.archivedAt == nil else { return }

        hasReportedTurnEnded = true
        _ = try? await store.enqueueDelivery(
            Delivery(
                targetSessionID: parentID,
                sourceWorkspaceID: workspace.id,
                kind: .report,
                crew: message
            )
        )

        // `existingModel` rather than `model(for:)`: `workspace` here is the snapshot this model
        // was made with, and handing a stale one to `model(for:)` pushes it back into the live
        // model, which is the bug `notifyFinished` below is written around. A crew member's
        // orchestrator is in this same worktree, so the model it needs is one that already exists.
        guard let model = app.existingModel(for: workspace.id) else { return }
        let transcript = model.transcript(for: parent)
        await transcript.refreshQueue()
        await transcript.drain()
    }

    private func notifyFinished(result: AgentResult) async {
        guard let store else { return }
        // Every line below is about a worktree: an unread mark on a sidebar row, a workspace model
        // to refresh, a banner naming where the turn finished. A chat with none is a chat the
        // owner is looking at, so there is nothing to mark and nobody to tell.
        guard let workspace, let workspaceNow else { return }
        try? await store.touch(
            workspaceID: workspace.id, unread: app.selection.workspaceID != workspace.id
        )

        // `workspaceNow`, twice over: `model(for:)` pushes the value it is handed into the
        // live model, so the stale snapshot did not just misname the notification, it reverted
        // the model's row in memory (name, colour, unread) until the change feed repaired it.
        let model = app.model(for: workspaceNow)
        await model.onTurnFinished()

        NotificationService.shared.turnFinished(
            workspace: workspaceNow, result: result, wasCancelled: session.state == .cancelled
        )
    }
}

/// Small helpers that peek at a stored payload without decoding the whole event, used while
/// folding rows together. How a result went is read by `ToolResultSummary`, which lives in the
/// core so that telling a denial from a failure is covered by tests.
enum ParentProbe {
    static func parentToolUseID(_ payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object["parent_tool_use_id"] as? String
    }
}
