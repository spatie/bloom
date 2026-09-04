import Testing
import Foundation
@testable import BloomCore

@Suite("What holds a queued message")
struct DeliveryHoldTests {
    @Test("a running setup script holds everything behind it, on every backend")
    func setupWins() {
        let hold = DeliveryHold.of(
            isRunningSetup: true, isTurnRunning: true, isAwaitingQuestion: true
        )
        #expect(hold == .setup)
        for agent in AgentKind.allCases {
            #expect(!hold.allowsDelivery(on: agent))
        }
    }

    @Test("a question is named before the turn it is holding open")
    func questionBeatsTurn() {
        // The turn is still marked running while the agent waits on an answer, so the more useful
        // of the two true answers is the one that tells the reader what to do.
        let hold = DeliveryHold.of(
            isRunningSetup: false, isTurnRunning: true, isAwaitingQuestion: true
        )
        #expect(hold == .question)
    }

    /// **The half that did not change, and the half that did.** A running turn is still a running
    /// turn, because `WorkspaceMergeTool` asks for the case and a busy worktree is no safer to
    /// merge into on a backend that can hear a sentence. What it holds is now the backend's
    /// answer.
    @Test("a running turn is still named as one, whatever the backend does about it")
    func turnIsStillNamed() {
        let hold = DeliveryHold.of(
            isRunningSetup: false, isTurnRunning: true, isAwaitingQuestion: false
        )
        #expect(hold == .turn)
    }

    /// **This assertion used to read `!hold.allowsDelivery` for every backend at once**, and it
    /// was the whole of what this change is about: a message typed during a turn waited for a turn
    /// that would have taken it. See `AgentKind.acceptsMidTurnMessage` for the measurement behind
    /// each answer below.
    @Test("a running turn holds the queue only where a line cannot be written into one")
    func turnHoldsPerBackend() {
        let hold = DeliveryHold.turn
        #expect(hold.allowsDelivery(on: .claudeCode))
        #expect(hold.allowsDelivery(on: .codex))
        #expect(!hold.allowsDelivery(on: .cursor))
        #expect(!hold.allowsDelivery(on: .openCode))
        for agent in AgentKind.allCases {
            #expect(hold.allowsDelivery(on: agent) == agent.acceptsMidTurnMessage)
        }
    }

    /// The two that are not about a protocol, so no backend gets to answer them differently. A
    /// worktree with nothing installed has nothing to work with, and a turn blocked on a
    /// permission answer is not reading anything else, which `SessionLifecycle` says again by
    /// refusing `turnStarted` from `waiting`.
    @Test("a question and a setup script hold on every backend, including the two that take a message mid turn")
    func questionAndSetupHoldEverywhere() {
        for agent in AgentKind.allCases {
            #expect(!DeliveryHold.question.allowsDelivery(on: agent))
            #expect(!DeliveryHold.setup.allowsDelivery(on: agent))
        }
    }

    @Test("only a runnable backend claims to take a message mid turn")
    func onlyRunnableBackendsAccept() {
        // Not a judgement about Cursor or OpenCode: neither has a runner, so there is no turn to
        // write into. A backend that grows one has to measure this rather than inherit it.
        for agent in AgentKind.allCases where agent.acceptsMidTurnMessage {
            #expect(agent.canRunWorkspaces)
        }
    }

    @Test("a setup script that failed holds nothing, so the queue still moves")
    func failedSetupDoesNotHold() {
        // The workspace is not asked about its setup failure at all any more: what failed is said
        // in the red setup row, the alert, the notification and the sidebar, and none of those is
        // a reason to leave a chat that cannot be spoken to. See `DeliveryHold`.
        let hold = DeliveryHold.of(
            isRunningSetup: false, isTurnRunning: false, isAwaitingQuestion: false
        )
        #expect(hold == .none)
        #expect(hold.allowsDelivery(on: .claudeCode))
    }

    @Test("an idle session lets the queue move, on every backend")
    func idleDelivers() {
        let hold = DeliveryHold.of(
            isRunningSetup: false, isTurnRunning: false, isAwaitingQuestion: false
        )
        #expect(hold == .none)
        for agent in AgentKind.allCases {
            #expect(hold.allowsDelivery(on: agent))
        }
    }

    /// **A caption may not promise a wait that is not happening.** The sentences are pinned here
    /// rather than in a view precisely so one cannot quietly start lying, and the one that could
    /// have is "Goes when this turn ends" on a backend where the drain no longer waits for it.
    @Test("everything that is holding something says what, and nothing else says anything")
    func everyHoldSpeaks() {
        for agent in AgentKind.allCases {
            for hold in DeliveryHold.allCases {
                if hold.allowsDelivery(on: agent) {
                    #expect(hold.sentence(on: agent) == nil)
                } else {
                    #expect(hold.sentence(on: agent)?.isEmpty == false)
                }
            }
        }
    }

    @Test("a running turn says nothing where the message goes into it")
    func aTurnThatHoldsNothingSaysNothing() {
        #expect(DeliveryHold.turn.sentence(on: .claudeCode) == nil)
        #expect(DeliveryHold.turn.sentence(on: .codex) == nil)
        #expect(DeliveryHold.turn.sentence(on: .cursor) == "Goes when this turn ends.")
    }

    @Test("the two that hold everywhere say the same thing everywhere")
    func heldSentencesDoNotVaryByBackend() {
        for agent in AgentKind.allCases {
            #expect(DeliveryHold.setup.sentence(on: agent) == "Goes as soon as setup finishes.")
            #expect(
                DeliveryHold.question.sentence(on: agent)
                    == "Goes once you have answered the question above."
            )
        }
        // Nothing to wait on, so nothing to say. See `DeliveryHold.sentence(on:)`.
        for agent in AgentKind.allCases {
            #expect(DeliveryHold.none.sentence(on: agent) == nil)
        }
    }
}

/// **What immediate delivery does to the order things were asked for, which is the promise the
/// table exists to keep.** The rule chosen: the front of the queue always goes first, and the
/// backend decides only how many may leave in one pass. Nothing typed during a turn can overtake
/// something queued before it on any backend.
@Suite("How much of the queue may go at once")
struct DeliveryDeliverableTests {
    private func waiting(_ bodies: String...) -> [Delivery] {
        bodies.map { Delivery(targetSessionID: SessionID("s"), body: $0) }
    }

    @Test("a hold that holds lets nothing go, whatever the backend")
    func heldLetsNothingGo() {
        let queue = waiting("first", "second")
        for agent in AgentKind.allCases {
            for hold in DeliveryHold.allCases where !hold.allowsDelivery(on: agent) {
                #expect(Delivery.deliverable(from: queue, hold: hold, on: agent).isEmpty)
                #expect(Delivery.next(from: queue, hold: hold, on: agent) == nil)
            }
        }
    }

    /// The old rule, kept where its reason still holds: handing over the front starts a turn, and
    /// on a backend that will not read a line written into one, that turn holds the rest.
    @Test("a backend that cannot take a message mid turn hands over one")
    func oneAtATimeWhereATurnHolds() {
        let queue = waiting("first", "second", "third")
        let going = Delivery.deliverable(from: queue, hold: .none, on: .cursor)
        #expect(going.map(\.body) == ["first"])
        #expect(Delivery.deliverable(from: queue, hold: .turn, on: .cursor).isEmpty)
    }

    /// **And why it does not survive on a backend that takes one.** Holding the second message
    /// back would put it under "Goes when this turn ends", and the owner's next sentence would
    /// falsify it: `submit` drains, the drain takes the front, and the front would go mid turn.
    @Test("a backend that takes a message mid turn empties the queue, in the order it was asked for")
    func theQueueEmptiesInOrder() {
        let queue = waiting("first", "second", "third")
        for agent in AgentKind.allCases where agent.acceptsMidTurnMessage {
            #expect(
                Delivery.deliverable(from: queue, hold: .none, on: agent).map(\.body)
                    == ["first", "second", "third"]
            )
            #expect(
                Delivery.deliverable(from: queue, hold: .turn, on: agent).map(\.body)
                    == ["first", "second", "third"]
            )
        }
    }

    /// The invariant behind the whole table, stated over every backend and every hold: whatever
    /// may go goes in the order it was asked for, and `next` is the head of it.
    @Test("what may go is always a prefix of the queue, in its own order")
    func alwaysAPrefixInOrder() {
        let queue = waiting("first", "second", "third")
        for agent in AgentKind.allCases {
            for hold in DeliveryHold.allCases {
                let going = Delivery.deliverable(from: queue, hold: hold, on: agent)
                #expect(going.map(\.id) == queue.prefix(going.count).map(\.id))
                #expect(Delivery.next(from: queue, hold: hold, on: agent)?.id == going.first?.id)
            }
        }
    }
}

@Suite("The delivery queue", .tags(.persistence), .scratchDirectory)
struct DeliveryStoreTests {
    /// A session to address deliveries at. Its workspace and project are only there because a
    /// session row needs one.
    private func makeSession(in store: Store, label: String = "s") async throws -> Session {
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(label)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/r-\(label)-w", baseBranch: "main"
        ))
        return try await store.upsert(Session(workspaceID: workspace.id, title: "chat"))
    }

    /// The bug this table was built for, written down.
    ///
    /// The owner opened a workspace with "list the technologies used", typed "test" into the
    /// composer while the setup script was still running, and the agent answered "test" first. The
    /// two went by different routes: the opening prompt waited inside the setup task, and the
    /// composer handed its line straight to the runner, because nothing marks a session busy while
    /// its worktree is being set up. Whichever continuation resumed first won.
    ///
    /// One queue, and the order out is the order in.
    @Test("hands back what was asked for first, first")
    func keepsTheOrderItWasAsked() async throws {
        let store = try makeTestStore("deliveries")
        let session = try await makeSession(in: store)

        try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "list the technologies used")
        )
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "test"))

        let pending = try await store.pendingDeliveries(sessionID: session.id)
        #expect(pending.map(\.body) == ["list the technologies used", "test"])
    }

    /// A timestamp is not a total order. The opening prompt is enqueued the moment the workspace
    /// is adopted, and on a fast machine a second one can land in the same millisecond; ordering
    /// on `created_at` alone left it to SQLite which came back first.
    @Test("keeps the order even when two land in the same instant")
    func breaksTiesByInsertionOrder() async throws {
        let store = try makeTestStore("deliveries-tie")
        let session = try await makeSession(in: store, label: "tie")
        let instant = Date()

        for body in ["first", "second", "third", "fourth"] {
            try await store.enqueueDelivery(
                Delivery(targetSessionID: session.id, body: body, createdAt: instant)
            )
        }

        let pending = try await store.pendingDeliveries(sessionID: session.id)
        #expect(pending.map(\.body) == ["first", "second", "third", "fourth"])
    }

    /// The owner's bug, as a story, in the one place the suite can reach it.
    ///
    /// He opened a workspace with "list the technologies used", typed "test" into the composer
    /// while the setup script was still running, and the agent answered "test" first. There were
    /// two routes in and they raced: the opening prompt waited inside the setup task, and the
    /// composer handed its line straight to the runner, since nothing marks a session busy while
    /// its worktree is being built.
    ///
    /// One queue, one order, and one thing allowed to move it.
    @Test("hands over the opening prompt before anything typed while setup was running")
    func openingPromptGoesBeforeWhatWasTypedDuringSetup() async throws {
        let store = try makeTestStore("deliveries-opening")
        let session = try await makeSession(in: store, label: "opening")

        // The create window, before the script starts.
        try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "list the technologies used")
        )
        // And the composer, a moment later, while it is still running.
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "test"))

        // Nothing goes anywhere while the worktree is still being built, whoever asked.
        let duringSetup = try await store.pendingDeliveries(sessionID: session.id)
        for agent in AgentKind.allCases {
            #expect(Delivery.next(from: duringSetup, hold: .setup, on: agent) == nil)
        }

        // The script finishes, and the first thing asked for is the first thing sent.
        let first = try #require(Delivery.next(from: duringSetup, hold: .none, on: .claudeCode))
        #expect(first.body == "list the technologies used")
        try await store.markDelivered(id: first.id)

        // And the rest is what was typed second, whenever it goes.
        //
        // **This used to assert that a running turn held it back on every backend**, which was the
        // coarse answer this change removed: on Claude Code and Codex the turn the first one
        // started takes the second as well. What the bug was ever about is the line below it,
        // which is unchanged and is the whole promise: the second thing typed is the second thing
        // handed over.
        let duringTurn = try await store.pendingDeliveries(sessionID: session.id)
        #expect(Delivery.next(from: duringTurn, hold: .turn, on: .cursor) == nil)
        #expect(Delivery.next(from: duringTurn, hold: .turn, on: .claudeCode)?.body == "test")
        #expect(Delivery.next(from: duringTurn, hold: .none, on: .claudeCode)?.body == "test")
    }

    @Test("a delivered message leaves the queue and stays out of it")
    func deliveredLeavesTheQueue() async throws {
        let store = try makeTestStore("deliveries-drain")
        let session = try await makeSession(in: store, label: "drain")
        let first = try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "one")
        )
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "two"))

        try await store.markDelivered(id: first.id)

        let pending = try await store.pendingDeliveries(sessionID: session.id)
        #expect(pending.map(\.body) == ["two"])
    }

    /// Quitting Bloom with something queued is one of the four things a queued message has to
    /// survive, and it is the reason this is a table rather than an array in a view model.
    @Test("survives the process that queued it")
    func survivesARelaunch() async throws {
        let path = TestScratch.unique("deliveries-relaunch") + ".sqlite"
        let store = try Store(path: path)
        let session = try await makeSession(in: store, label: "relaunch")
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "still here"))

        let reopened = try Store(path: path)
        let pending = try await reopened.pendingDeliveries(sessionID: session.id)
        #expect(pending.map(\.body) == ["still here"])
    }

    @Test("changing your mind takes it back out")
    func cancelRemovesIt() async throws {
        let store = try makeTestStore("deliveries-cancel")
        let session = try await makeSession(in: store, label: "cancel")
        let one = try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "one")
        )
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "two"))

        #expect(try await store.cancelDelivery(id: one.id))
        #expect(try await store.pendingDeliveries(sessionID: session.id).map(\.body) == ["two"])
    }

    /// A cancel pressed on the frame the drain fires must not read as having unsaid something the
    /// agent is already running.
    @Test("refuses to cancel a message that has already gone")
    func cancelWillNotUnsendIt() async throws {
        let store = try makeTestStore("deliveries-gone")
        let session = try await makeSession(in: store, label: "gone")
        let one = try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "one")
        )
        try await store.markDelivered(id: one.id)

        // False, and that is the whole of what the caller needs: it says the sentence was not
        // taken back rather than that nothing was there, which are two different things to tell
        // somebody who has just pressed Delete. See `PendingMessageDiscard.alreadySentSentence`.
        #expect(try await store.cancelDelivery(id: one.id) == false)
        #expect(try await store.pendingDeliveries(sessionID: session.id).isEmpty)

        // Still there, rather than deleted: putting it back finds the row the cancel refused to
        // touch, which is what tells the two outcomes apart.
        try await store.restoreDelivery(id: one.id)
        #expect(try await store.pendingDeliveries(sessionID: session.id).map(\.body) == ["one"])
    }

    /// The runner refusing to start is the one case where a retired delivery has to come back: the
    /// drain marks it gone before handing it over so the bubble does not flash, and nothing was
    /// ever said.
    @Test("comes back when the agent would not start")
    func restorePutsItBack() async throws {
        let store = try makeTestStore("deliveries-restore")
        let session = try await makeSession(in: store, label: "restore")
        let one = try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "one")
        )
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "two"))

        try await store.markDelivered(id: one.id)
        try await store.restoreDelivery(id: one.id)

        #expect(try await store.pendingDeliveries(sessionID: session.id).map(\.body) == ["one", "two"])
    }

    @Test("addresses a chat, not a workspace")
    func addressesOneChat() async throws {
        let store = try makeTestStore("deliveries-address")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-address"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/r-address-w", baseBranch: "main"
        ))
        let one = try await store.upsert(Session(workspaceID: workspace.id, title: "one"))
        let two = try await store.upsert(Session(workspaceID: workspace.id, title: "two"))

        try await store.enqueueDelivery(Delivery(targetSessionID: one.id, body: "for one"))

        #expect(try await store.pendingDeliveries(sessionID: one.id).count == 1)
        #expect(try await store.pendingDeliveries(sessionID: two.id).isEmpty)
    }

    /// The other half of this table, and the reason it carries columns this app does not write
    /// yet: a child workspace's report is the same question with the same answer. See
    /// `bloom-handover/mcp-design.md`.
    @Test("carries a report from another workspace in the same order")
    func carriesAgentDeliveriesToo() async throws {
        let store = try makeTestStore("deliveries-kinds")
        let session = try await makeSession(in: store, label: "kinds")
        let child = WorkspaceID("ws-1f2a")

        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "mine"))
        try await store.enqueueDelivery(Delivery(
            targetSessionID: session.id,
            sourceWorkspaceID: child,
            kind: .report,
            verdict: "done",
            body: "Rebuilt the index migration."
        ))

        let pending = try await store.pendingDeliveries(sessionID: session.id)
        #expect(pending.map(\.kind) == [.owner, .report])
        #expect(pending[1].sourceWorkspaceID == child)
        #expect(pending[1].verdict == "done")
    }
}

/// The owner pressed Return and his own sentence did not appear until the agent began answering
/// it. The runner writes the user row as part of starting the turn, and the transcript only read
/// rows back when an agent event arrived, so between the process launch and the model's first word
/// he typed into a transcript that showed no sign of having heard him.
///
/// The transcript now draws the sentence on the frame the key goes down, and this is the decision
/// it needs to take there: sent, or waiting. It has to agree with the drain, always, or the bubble
/// says one thing and the queue does another.
@Suite("What the transcript draws the instant Return is pressed")
struct DeliveryEchoTests {
    private func waiting(_ bodies: String...) -> [Delivery] {
        bodies.map { Delivery(targetSessionID: SessionID("s"), body: $0) }
    }

    @Test("a message typed into an idle chat has gone, so it is drawn as one that has")
    func idleGoesAtOnce() {
        for agent in AgentKind.allCases {
            #expect(Delivery.goesImmediately(behind: [], hold: .none, on: agent))
        }
    }

    @Test("a message typed while anything is holding the queue is drawn as waiting")
    func heldIsDrawnAsWaiting() {
        for agent in AgentKind.allCases {
            for hold in DeliveryHold.allCases where !hold.allowsDelivery(on: agent) {
                #expect(!Delivery.goesImmediately(behind: [], hold: hold, on: agent))
            }
        }
    }

    /// **The bubble the owner asked about.** He typed while a turn was running and read "Goes when
    /// this turn ends" under it. On a backend that takes a message mid turn it does not wait, so
    /// it is drawn as said, and no bubble promises anything on its behalf.
    @Test("a message typed during a turn has gone, where the turn can take it")
    func typedDuringATurnGoesAtOnce() {
        #expect(Delivery.goesImmediately(behind: [], hold: .turn, on: .claudeCode))
        #expect(Delivery.goesImmediately(behind: [], hold: .turn, on: .codex))
        #expect(!Delivery.goesImmediately(behind: [], hold: .turn, on: .cursor))
    }

    @Test("a message typed behind one that is still waiting waits too")
    func queuedBehindWaits() {
        // Nothing is holding this session, and the message still does not go: the one in front of
        // it does. Drawing it as sent would be the transcript claiming an order the drain will
        // not honour.
        #expect(!Delivery.goesImmediately(behind: waiting("first"), hold: .none, on: .claudeCode))
    }

    /// **The ordering promise, on the backend that changed.** Immediate delivery is not a
    /// reordering: a message typed during a turn still joins the back of a queue that already has
    /// something in it, and the drain still takes the front.
    @Test("nothing typed during a turn overtakes what was queued before it")
    func nothingOvertakes() {
        let queued = waiting("asked for first")
        for agent in AgentKind.allCases where agent.acceptsMidTurnMessage {
            #expect(!Delivery.goesImmediately(behind: queued, hold: .turn, on: agent))
            #expect(Delivery.next(from: queued, hold: .turn, on: agent)?.body == "asked for first")
        }
    }

    @Test("the bubble and the drain never disagree about what goes next")
    func echoAgreesWithTheDrain() {
        // The invariant, stated over every shape the queue can be in and every backend: what the
        // transcript draws as sent is exactly what the drain would hand to the runner. Asked of
        // `next`, which is the ordering rule itself, so a change to that rule cannot leave this
        // behind.
        let queues = [waiting(), waiting("first"), waiting("first", "second")]
        for agent in AgentKind.allCases {
            for hold in DeliveryHold.allCases {
                for queue in queues {
                    let typed = Delivery(targetSessionID: SessionID("s"), body: "just typed")
                    let goesNext = Delivery.next(
                        from: queue + [typed], hold: hold, on: agent
                    )?.id == typed.id
                    #expect(
                        Delivery.goesImmediately(behind: queue, hold: hold, on: agent) == goesNext
                    )
                }
            }
        }
    }
}

/// The owner presses Stop, and what he typed while the agent was working is still sitting under
/// the transcript. Not draining after a Stop is right: he stepped in, and a message queued four
/// minutes ago going out into the silence he just made is the opposite of what Stop is for. What
/// was wrong is what happened to the message afterwards, which was nothing, under a bubble that
/// had been promising it would go when this turn ended.
///
/// So Stop empties the queue into the composer, where the words can be read, changed and sent
/// again by the person who wrote them. See `PendingMessageReturn`.
@Suite("What a Stop leaves behind")
struct PendingMessageReturnTests {
    private func typed(_ body: String, delivered: Bool = false) -> Delivery {
        Delivery(
            targetSessionID: SessionID("s"),
            body: body,
            deliveredAt: delivered ? Date() : nil
        )
    }

    private func fromAnAgent(_ text: String) -> Delivery {
        Delivery(
            targetSessionID: SessionID("s"),
            sourceWorkspaceID: WorkspaceID("ws-1f2a"),
            kind: .message,
            crew: CrewMessage.said(from: "indexer", text: text, sender: .subagent)
        )
    }

    @Test("the whole queue comes back, in the order it was asked for")
    func everythingReturnsInOrder() {
        let queue = [typed("first"), typed("second"), typed("third")]
        #expect(PendingMessageReturn.returning(from: queue).map(\.body) == ["first", "second", "third"])
        #expect(PendingMessageReturn.draft(taking: queue, into: "") == "first\n\nsecond\n\nthird")
    }

    /// The one thing this must never do. A queue coming back into a box somebody is typing in is
    /// only an improvement if what they are typing survives it.
    @Test("a draft already in the composer is kept, and goes last")
    func theDraftIsNotDestroyed() {
        let joined = PendingMessageReturn.draft(
            taking: [typed("first"), typed("second")], into: "half a thought"
        )
        #expect(joined == "first\n\nsecond\n\nhalf a thought")
    }

    /// The reading `PendingMessageDiscard.recovery` takes, inherited rather than restated: a box
    /// holding three newlines is not something anybody is in the middle of writing.
    @Test("a blank composer counts as empty and its whitespace does not survive")
    func blankDraftCountsAsEmpty() {
        #expect(PendingMessageReturn.draft(taking: [typed("one")], into: " \n\n ") == "one")
    }

    @Test("an empty queue leaves the composer exactly as it was")
    func nothingToReturnChangesNothing() {
        #expect(PendingMessageReturn.draft(taking: [], into: "half a thought") == "half a thought")
    }

    /// The whole point of folding through `PendingMessageEdit`: a Stop with one message queued has
    /// to leave the composer in the state pressing the pencil on it would have.
    @Test("returning one message is the same move as editing it")
    func oneMessageMatchesTheEditButton() {
        for draft in ["", "  ", "half a thought"] {
            let one = typed("one")
            #expect(
                PendingMessageReturn.draft(taking: [one], into: draft)
                    == PendingMessageEdit.draft(taking: one, into: draft)
            )
        }
    }

    /// **A crew message is not the owner's writing.** It is another agent's sentence, drawn in its
    /// own row rather than in his bubble, and putting it in his composer would have him send back
    /// words he never wrote. It waits where it is.
    @Test("something an agent said stays in the queue")
    func crewMessagesStayQueued() {
        let queue = [typed("mine"), fromAnAgent("the index is rebuilt")]
        #expect(PendingMessageReturn.returning(from: queue).map(\.body) == ["mine"])
        #expect(PendingMessageReturn.keeping(from: queue).map(\.kind) == [.message])
    }

    /// The same answer Edit gives, for the same reason: neither the chips nor the paths survive a
    /// round trip through a text box, so the message keeps its place rather than coming back as
    /// the machine's rendering of itself.
    @Test("a message carrying attachments stays in the queue")
    func attachmentsStayQueued() {
        let attached = typed(AttachmentTrailer.compose(text: "look at this", paths: ["a.png"]))
        let queue = [typed("mine"), attached]
        #expect(PendingMessageReturn.returning(from: queue).map(\.body) == ["mine"])
        #expect(PendingMessageReturn.keeping(from: queue).count == 1)
    }

    @Test("a message that has already gone is not offered back")
    func deliveredIsNotReturned() {
        #expect(!PendingMessageReturn.canReturn(typed("gone", delivered: true)))
    }

    /// Every message is in exactly one of the two answers, and both keep the queue's order. A
    /// message in neither is one stranded by the very fix this suite is about.
    @Test("what comes back and what stays partition the queue")
    func thePartitionIsComplete() {
        let queue = [
            typed("first"),
            fromAnAgent("from the indexer"),
            typed(AttachmentTrailer.compose(text: "look", paths: ["a.png"])),
            typed("last"),
        ]
        let returning = PendingMessageReturn.returning(from: queue)
        let keeping = PendingMessageReturn.keeping(from: queue)
        #expect(returning.count + keeping.count == queue.count)
        #expect(returning.map(\.body) == ["first", "last"])
        #expect(keeping.map(\.id) == [queue[1].id, queue[2].id])
    }
}

/// One message goes now, in place of the turn it was waiting behind, and the rest of the queue
/// does not notice. See `DeliverySteer`.
@Suite("Steering one message past the rest")
struct DeliverySteerTests {
    private func typed(_ body: String, delivered: Bool = false) -> Delivery {
        Delivery(
            targetSessionID: SessionID("s"),
            body: body,
            deliveredAt: delivered ? Date() : nil
        )
    }

    /// **This used to be offered on every backend while a turn ran.** It still is on one that
    /// cannot take a message mid turn, where stopping the turn is the only way to be heard. Where
    /// the message can simply go, spending the turn to make room for it buys nothing and costs
    /// whatever that turn had done, so the button is not offered and Stop keeps the job under its
    /// own name. See `DeliverySteer.canSteer`.
    @Test("offered only while there is a turn to interrupt, and only where interrupting is the way in")
    func onlyDuringATurn() {
        let one = typed("one")
        for hold in DeliveryHold.allCases {
            #expect(!DeliverySteer.canSteer(one, hold: hold, on: .claudeCode))
            #expect(!DeliverySteer.canSteer(one, hold: hold, on: .codex))
            #expect(DeliverySteer.canSteer(one, hold: hold, on: .cursor) == (hold == .turn))
        }
    }

    /// Stated as the rule rather than as a list, so a backend that grows the capability loses the
    /// button by answering one question.
    @Test("a backend that takes a message mid turn never offers it")
    func midTurnBackendsNeverSteer() {
        let one = typed("one")
        for agent in AgentKind.allCases where agent.acceptsMidTurnMessage {
            #expect(!DeliverySteer.canSteer(one, hold: .turn, on: agent))
        }
    }

    @Test("a message that has already gone cannot be steered")
    func deliveredCannotSteer() {
        #expect(!DeliverySteer.canSteer(typed("gone", delivered: true), hold: .turn, on: .cursor))
    }

    /// Interrupting an agent is a person's decision. A crew message is drawn in its own row and
    /// never carries these controls, and this is the rule behind that rather than a fact about
    /// which view is used.
    @Test("a message from another agent carries no Steer")
    func crewCannotSteer() {
        let fromAnAgent = Delivery(
            targetSessionID: SessionID("s"),
            sourceWorkspaceID: WorkspaceID("ws-1f2a"),
            kind: .message,
            crew: CrewMessage.said(from: "indexer", text: "done", sender: .subagent)
        )
        #expect(!DeliverySteer.canSteer(fromAnAgent, hold: .turn, on: .cursor))
    }

    /// Where Steer parts company with Edit. Nothing is being turned back into text, so a body the
    /// composer could not hold is a body the agent can still be handed exactly as it stood.
    @Test("a message carrying attachments can be steered, unlike edited")
    func attachmentsCanStillSteer() {
        let attached = typed(AttachmentTrailer.compose(text: "look at this", paths: ["a.png"]))
        #expect(!PendingMessageEdit.canEdit(attached))
        #expect(DeliverySteer.canSteer(attached, hold: .turn, on: .cursor))
    }

    /// The ordering rule, stated over every position in the queue: one message leaves, and what is
    /// left is what was left, in the order it was asked for. Nothing is promoted behind it.
    @Test("everything else keeps its place and its order, whichever one is steered")
    func theRestIsUntouched() {
        let queue = [typed("first"), typed("second"), typed("third")]
        let expected = [["second", "third"], ["first", "third"], ["first", "second"]]
        for (index, chosen) in queue.enumerated() {
            let rest = DeliverySteer.queue(after: chosen, from: queue)
            #expect(rest.map(\.body) == expected[index])
        }
    }

    /// Steering the front of the queue is the drain's own move, so the two must not disagree about
    /// what is left behind.
    @Test("steering the front leaves what the drain would have left")
    func steeringTheFrontMatchesTheDrain() throws {
        let queue = [typed("first"), typed("second"), typed("third")]
        let front = try #require(Delivery.next(from: queue, hold: .none, on: .cursor))
        #expect(DeliverySteer.queue(after: front, from: queue).map(\.body) == ["second", "third"])
    }
}
