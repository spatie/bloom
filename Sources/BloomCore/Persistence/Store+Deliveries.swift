import Foundation

extension Store {
    // MARK: - Deliveries

    /// Queue acceptance and draft removal either both commit or neither does. A newer saved
    /// draft belongs to the next message and must survive an earlier submission completing.
    @discardableResult
    public func enqueueDelivery(
        _ delivery: Delivery, clearingDraftMatching draft: String?, sourcePlan: PlanArtefact? = nil
    ) throws -> Delivery {
        try db.transaction {
            let queued = try enqueueDelivery(delivery)
            if let sourcePlan { try queuePlanSource(sourcePlan, delivery: queued) }
            if let draft, try self.draft(sessionID: delivery.targetSessionID) == draft {
                try saveDraft(sessionID: delivery.targetSessionID, body: "")
            }
            return queued
        }
    }

    /// Everything asked for on this session that has not gone yet, oldest first.
    ///
    /// `created_at, rowid` and not `created_at` alone. The opening prompt and a sentence typed
    /// while the setup script is still running can land in the same millisecond, and putting them
    /// back in the wrong order is the bug this whole table exists to fix.
    public func pendingDeliveries(sessionID: SessionID) throws -> [Delivery] {
        try db.query(
            """
            SELECT * FROM deliveries
            WHERE target_session_id = ? AND delivery_state IN ('pending', 'uncertain')
            ORDER BY created_at, rowid
            """,
            [.text(sessionID)]
        ).map(Self.delivery(from:))
    }

    /// Puts one at the back of the queue.
    ///
    /// The value is built here and now, so the id and the timestamp it is handed back with are
    /// the ones on disk. Callers hold that id to cancel the row again.
    @discardableResult
    public func enqueueDelivery(_ delivery: Delivery) throws -> Delivery {
        var delivery = delivery
        if delivery.kind == .owner, delivery.interactionMode == nil {
            delivery.interactionMode = try session(id: delivery.targetSessionID)?.interactionMode
        }
        try db.run(
            """
            INSERT INTO deliveries
                (id, target_session_id, source_workspace_id, kind, verdict, body, crew_payload,
                 created_at, delivered_at, delivered_seq, delivery_state, interaction_mode, provider_turn_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(delivery.id),
                .text(delivery.targetSessionID),
                delivery.sourceWorkspaceID.map { .text($0) } ?? .null,
                .text(delivery.kind.rawValue),
                delivery.verdict.map { .text($0) } ?? .null,
                .text(delivery.body),
                delivery.crewPayload.map { .blob($0) } ?? .null,
                .double(delivery.createdAt.timeIntervalSince1970),
                delivery.deliveredAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                delivery.deliveredSeq.map { .int(Int64($0)) } ?? .null,
                .text(delivery.state.rawValue),
                delivery.interactionMode.map { .text($0.rawValue) } ?? .null,
                delivery.providerTurnID.map { .text($0) } ?? .null,
            ]
        )
        return delivery
    }

    /// Claim and transcript insertion share a transaction. Retrying the same delivery reuses
    /// its message, so a crash or a lost acknowledgement cannot duplicate the user's words.
    public func claimDelivery(id: DeliveryID) throws -> Bool {
        try db.transaction {
            guard let row = try db.query("SELECT * FROM deliveries WHERE id = ?", [.text(id)]).first,
                  row.string("delivery_state") == "pending" else { return false }
            let delivery = Self.delivery(from: row)
            var seq = delivery.deliveredSeq
            if seq == nil {
                // `uuid` is the id the runner sends this message under, so a rewind can name
                // it. See `ClaudeRewind.turnUUID(for:)`.
                let payload = delivery.crewPayload ?? Data(JSONValue.object([
                    "type": .string("user"),
                    "message": .object(["role": .string("user"), "content": .array([
                        .object(["type": .string("text"), "text": .string(delivery.body)]),
                    ])]),
                    "uuid": .string(ClaudeRewind.turnUUID(for: delivery.id)),
                ]).compactJSON.utf8)
                let next = try nextSeqLocked(sessionID: delivery.targetSessionID)
                _ = try insert(Message(sessionID: delivery.targetSessionID, seq: next,
                    kind: delivery.crewPayload == nil ? .user : .crew, payload: payload,
                    createdAt: delivery.createdAt))
                seq = next
            }
            try db.run("UPDATE deliveries SET delivery_state = 'claimed', delivered_seq = ? WHERE id = ?", [
                seq.map { .int(Int64($0)) } ?? .null, .text(id),
            ])
            return true
        }
    }

    /// Written before touching the provider. A crash from here on has an unknown outcome;
    /// neither a timeout nor a restart is evidence that it is safe to send again.
    public func beginDeliveryDispatch(id: DeliveryID) throws {
        try db.run("UPDATE deliveries SET delivery_state = 'uncertain' WHERE id = ? AND delivery_state = 'claimed'", [.text(id)])
        guard db.changedRowCount == 1 else { throw DeliveryDispatchError.notClaimed }
    }

    public func acceptDelivery(id: DeliveryID, providerTurnID: String? = nil) throws {
        try db.transaction {
            try db.run("UPDATE deliveries SET delivery_state = 'accepted', delivered_at = ?, provider_turn_id = ? WHERE id = ? AND delivery_state = 'uncertain'", [
                .double(Date().timeIntervalSince1970), providerTurnID.map { .text($0) } ?? .null, .text(id),
            ])
            if db.changedRowCount == 1, let accepted = try delivery(id: id) {
                try acceptPlanSource(delivery: accepted)
                // The agent has it, so the bubble in the sending chat stops saying "queued". See
                // `markDelivered`, the other door a delivery goes out through.
                try db.run(
                    "UPDATE workspace_messages SET state = 'delivered', delivered_at = ? WHERE delivery_id = ? AND state = 'queued'",
                    [.double(accepted.deliveredAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970), .text(id)]
                )
            }
        }
    }

    public func delivery(id: DeliveryID) throws -> Delivery? {
        try db.query("SELECT * FROM deliveries WHERE id = ?", [.text(id)]).first.map(Self.delivery(from:))
    }

    /// Only claims known not to have reached dispatch are automatically made pending again.
    /// Uncertain attempts remain visible and require an explicit resend.
    public func recoverDeliveryClaims() throws {
        try db.run("UPDATE deliveries SET delivery_state = 'pending' WHERE delivery_state = 'claimed'")
    }

    public func releaseDeliveryClaim(id: DeliveryID) throws {
        try db.run("UPDATE deliveries SET delivery_state = 'pending' WHERE id = ? AND delivery_state = 'claimed'", [.text(id)])
    }

    /// Marks one as gone.
    ///
    /// Named columns rather than a whole-value write, which is the rule the head of this file is
    /// about: a delivery is read by the transcript to draw it and written by the drain to retire
    /// it, and those two are not ordered with respect to each other.
    ///
    /// `seq` is what the delivery became in the `messages` table where the caller knows it, which
    /// the owner's own path does not: the runner writes that row as part of starting the turn.
    /// See `Delivery.deliveredSeq`.
    @discardableResult
    public func markDelivered(id: DeliveryID, seq: Int? = nil, at date: Date = Date()) throws -> Bool {
        try db.run(
            "UPDATE deliveries SET delivered_at = ?, delivered_seq = ?, delivery_state = 'accepted' WHERE id = ? AND delivery_state = 'pending'",
            [.double(date.timeIntervalSince1970), seq.map { .int(Int64($0)) } ?? .null, .text(id)]
        )
        let marked = db.changedRowCount == 1
        // A message from another workspace follows its delivery, here rather than in the drain, so
        // the bubble in the sending chat cannot say "queued" about a turn that is already running.
        if marked {
            try db.run(
                "UPDATE workspace_messages SET state = 'delivered', delivered_at = ? WHERE delivery_id = ? AND state = 'queued'",
                [.double(date.timeIntervalSince1970), .text(id)]
            )
        }
        return marked
    }

    /// Takes one back out of the queue, because whoever asked for it changed their mind.
    ///
    /// Only while it is still pending. A delivery that has gone is a turn the agent is already
    /// running, and deleting the row would not unsay it; the `WHERE` is what makes a cancel
    /// pressed on the same frame the drain fires a no-op rather than a lie.
    ///
    /// **Returns whether a row actually went**, because a no-op and a delete are two different
    /// things to tell the owner: one of them means the sentence is gone and the other means the
    /// agent is already reading it. The caller cannot work that out for itself, and it is the one
    /// thing the race turns on. See `PendingMessageDiscard.alreadySentSentence`.
    ///
    /// The look and the delete are two statements with no suspension between them, which is the
    /// same reason `update(workspaceID:)` reads inside the actor: nothing else can retire the row
    /// in the gap, because there is no gap.
    @discardableResult
    public func cancelDelivery(id: DeliveryID) throws -> Bool {
        try db.run("DELETE FROM deliveries WHERE id = ? AND delivery_state IN ('pending', 'uncertain')", [.text(id)])
        let removed = db.changedRowCount == 1
        // Whichever end cancelled it, the other end's bubble has to say so. See `markDelivered`.
        if removed {
            try db.run(
                "UPDATE workspace_messages SET state = 'cancelled' WHERE delivery_id = ? AND state = 'queued'",
                [.text(id)]
            )
        }
        return removed
    }

    /// Puts one back in the queue after a send that never started a turn.
    ///
    /// The drain retires a delivery before handing it over, so the bubble does not flash on screen
    /// for the one frame between the two. When the runner refuses to start there is nothing to
    /// retire it for, and a message the agent never received must go back to being pending rather
    /// than reading as sent.
    public func restoreDelivery(id: DeliveryID) throws {
        try db.run(
            "UPDATE deliveries SET delivered_at = NULL, delivery_state = 'pending', provider_turn_id = NULL WHERE id = ?",
            [.text(id)]
        )
        try db.run(
            "UPDATE workspace_messages SET state = 'queued', delivered_at = NULL WHERE delivery_id = ? AND state = 'delivered'",
            [.text(id)]
        )
    }

    // MARK: - Workspace messages

    /// Puts a message from another workspace in a chat's queue, and records it, in one transaction.
    ///
    /// One transaction because the two rows describe one thing from two ends: the delivery is what
    /// the receiving chat drains, and this row is what the sending chat draws. A delivery with no
    /// row would be a message its sender could never see the fate of; a row with no delivery would
    /// be a bubble saying "queued" for ever.
    @discardableResult
    public func enqueueWorkspaceMessage(
        _ message: WorkspaceMessage, into chat: Session
    ) throws -> WorkspaceMessage {
        try db.transaction {
            let delivery = try enqueueDelivery(Delivery(
                targetSessionID: chat.id,
                sourceWorkspaceID: message.source.workspaceID,
                kind: .message,
                crew: message.crewMessage,
                createdAt: message.createdAt
            ))
            try db.run(
                """
                INSERT INTO workspace_messages
                    (id, source_workspace_id, source_workspace_name, source_project_name,
                     source_session_id, source_chat, target_workspace_id, target_workspace_name,
                     target_project_name, target_session_id, target_chat, reply_session_id, body,
                     delivery_id, state, created_at, delivered_at, notify_when_done)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, NULL, ?)
                """,
                [
                    .text(message.id),
                    message.source.workspaceID.map { .text($0) } ?? .null,
                    .text(message.source.workspace),
                    .text(message.source.project),
                    message.source.sessionID.map { .text($0) } ?? .null,
                    .text(message.source.chat),
                    message.target.workspaceID.map { .text($0) } ?? .null,
                    .text(message.target.workspace),
                    .text(message.target.project),
                    .text(chat.id),
                    .text(chat.title),
                    message.replySessionID.map { .text($0) } ?? .null,
                    .text(message.text),
                    .text(delivery.id),
                    .double(message.createdAt.timeIntervalSince1970),
                    .int(message.notifyWhenDone ? 1 : 0),
                ]
            )
            // In the same transaction, so a message that asked to be told about is never in a
            // queue without the promise, and a promise never outlives a message that failed to go
            // in. A sender with no chat has nowhere to be told, and the tool has already said so.
            if message.notifyWhenDone, let watcher = message.source.sessionID,
               let targetWorkspaceID = message.target.workspaceID {
                try insert(WorkspaceDoneWatch(
                    cause: .message(message.id, state: .queued),
                    watcherSessionID: watcher,
                    target: WorkspaceMessageEnd(
                        workspaceID: targetWorkspaceID,
                        workspace: message.target.workspace,
                        project: message.target.project,
                        sessionID: chat.id,
                        chat: chat.title
                    ),
                    createdAt: message.createdAt
                ))
            }
            return try workspaceMessage(id: message.id) ?? message
        }
    }

    /// What one workspace has sent another since a moment, cancelled messages left out, newest
    /// first. The count `WorkspaceSayThrottle` brakes on.
    public func workspaceMessages(
        from source: WorkspaceID, to target: WorkspaceID, since: Date
    ) throws -> [WorkspaceMessage] {
        try db.query(
            """
            SELECT * FROM workspace_messages
            WHERE source_workspace_id = ? AND target_workspace_id = ? AND state != 'cancelled'
              AND created_at >= ?
            ORDER BY created_at DESC, rowid DESC
            """,
            [.text(source), .text(target), .double(since.timeIntervalSince1970)]
        ).map(Self.workspaceMessage(from:))
    }

    // MARK: - Workspace done watches

    /// Records a chat's request to hear when a workspace it started comes to rest. A message's
    /// watch is written by `enqueueWorkspaceMessage` instead, inside its transaction.
    public func addWorkspaceDoneWatch(_ watch: WorkspaceDoneWatch) throws {
        try insert(watch)
    }

    private func insert(_ watch: WorkspaceDoneWatch) throws {
        let messageID: SQLValue = if case .message(let id, _) = watch.cause { .text(id) } else { .null }
        try db.run(
            """
            INSERT INTO workspace_done_watches
                (id, message_id, watcher_session_id, target_workspace_id, target_workspace_name,
                 target_project_name, target_session_id, target_chat, created_at, notified_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            [
                .text(watch.id),
                messageID,
                .text(watch.watcherSessionID),
                watch.target.workspaceID.map { .text($0) } ?? .null,
                .text(watch.target.workspace),
                .text(watch.target.project),
                watch.target.sessionID.map { .text($0) } ?? .null,
                .text(watch.target.chat),
                .double(watch.createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// Every watch on a workspace that has not been spent, oldest first, each with its message's
    /// state as it is now. A watch whose message row has gone reads as cancelled, which spends it
    /// with nothing said.
    public func unspentWorkspaceDoneWatches(targetWorkspaceID: WorkspaceID) throws -> [WorkspaceDoneWatch] {
        try db.query(
            """
            SELECT w.*, m.state AS message_state FROM workspace_done_watches w
            LEFT JOIN workspace_messages m ON m.id = w.message_id
            WHERE w.target_workspace_id = ? AND w.notified_at IS NULL
            ORDER BY w.created_at, w.rowid
            """,
            [.text(targetWorkspaceID)]
        ).map(Self.workspaceDoneWatch(from:))
    }

    public func workspaceDoneWatch(id: WorkspaceDoneWatchID) throws -> WorkspaceDoneWatch? {
        try db.query(
            """
            SELECT w.*, m.state AS message_state FROM workspace_done_watches w
            LEFT JOIN workspace_messages m ON m.id = w.message_id
            WHERE w.id = ?
            """,
            [.text(id)]
        ).first.map(Self.workspaceDoneWatch(from:))
    }

    /// Spends a watch. True only for the call that spent it, which is what makes a notice go at
    /// most once: two endings arriving together both ask, and one of them changes the row.
    @discardableResult
    public func claimWorkspaceDoneWatch(id: WorkspaceDoneWatchID, at date: Date = Date()) throws -> Bool {
        try db.run(
            "UPDATE workspace_done_watches SET notified_at = ? WHERE id = ? AND notified_at IS NULL",
            [.double(date.timeIntervalSince1970), .text(id)]
        )
        return db.changedRowCount == 1
    }

    public func workspaceMessage(id: WorkspaceMessageID) throws -> WorkspaceMessage? {
        try db.query("SELECT * FROM workspace_messages WHERE id = ?", [.text(id)])
            .first.map(Self.workspaceMessage(from:))
    }

    public func workspaceMessage(deliveryID: DeliveryID) throws -> WorkspaceMessage? {
        try db.query("SELECT * FROM workspace_messages WHERE delivery_id = ?", [.text(deliveryID)])
            .first.map(Self.workspaceMessage(from:))
    }

    /// The last message from one workspace that reached another's agent.
    ///
    /// The reply path turns on this: its source chat is the chat an answer should land in.
    /// Delivered only, because a message still queued has not been read, so nothing can be
    /// answering it, and it may yet be cancelled.
    public func latestWorkspaceMessage(
        from source: WorkspaceID, to target: WorkspaceID
    ) throws -> WorkspaceMessage? {
        try db.query(
            """
            SELECT * FROM workspace_messages
            WHERE source_workspace_id = ? AND target_workspace_id = ? AND state = 'delivered'
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """,
            [.text(source), .text(target)]
        ).first.map(Self.workspaceMessage(from:))
    }

    /// Takes a queued message back out, from the chat that sent it. Nil when it had already gone,
    /// or is going.
    ///
    /// **Pending only, where the receiving chat's own Delete also takes `uncertain`.** A delivery is
    /// uncertain while its turn is being started: the crew row is already in the receiving
    /// transcript and the runner is waiting on the CLI. That chat's Delete is held off for exactly
    /// that window by the transcript that is dispatching it, and this side cannot see that
    /// transcript. Deleting here would tell the sender "its agent never saw it" about a turn that
    /// then starts, so a message that far along is treated as gone.
    @discardableResult
    public func cancelWorkspaceMessage(id: WorkspaceMessageID) throws -> WorkspaceMessage? {
        try db.transaction {
            guard let message = try workspaceMessage(id: id), message.state == .queued,
                  let deliveryID = message.deliveryID
            else { return nil }
            try db.run(
                "DELETE FROM deliveries WHERE id = ? AND delivery_state = 'pending'", [.text(deliveryID)]
            )
            guard db.changedRowCount == 1 else { return nil }
            try db.run(
                "UPDATE workspace_messages SET state = 'cancelled' WHERE id = ? AND state = 'queued'",
                [.text(id)]
            )
            return try workspaceMessage(id: id)
        }
    }
}
