import Foundation

extension Store {
    // MARK: - Row mapping

    static func repo(from row: Row) -> Repo {
        Repo(
            id: RepoID(row.string("id") ?? newID()),
            name: row.string("name") ?? "",
            path: row.string("path") ?? "",
            defaultBranch: row.string("default_branch") ?? "main",
            accent: row.string("accent") ?? Accent.all[0],
            sortOrder: Int(row.int("sort_order") ?? 0),
            collapsed: row.bool("collapsed"),
            hidden: row.bool("hidden"),
            createdAt: row.date("created_at") ?? Date(),
            iconPath: row.string("icon_path"),
            iconSource: RepoIconSource(rawValue: row.string("icon_source") ?? "") ?? .undetected
        )
    }

    static func workspace(from row: Row) -> Workspace {
        Workspace(
            id: WorkspaceID(row.string("id") ?? newID()),
            repoID: RepoID(row.string("repo_id") ?? ""),
            name: row.string("name") ?? "",
            branch: row.string("branch") ?? "",
            path: row.string("path") ?? "",
            baseBranch: row.string("base_branch") ?? "main",
            state: WorkspaceState(rawValue: row.string("state") ?? "active") ?? .active,
            setupState: SetupState(rawValue: row.string("setup_state") ?? "pending") ?? .pending,
            setupLog: row.string("setup_log") ?? "",
            sortOrder: Int(row.int("sort_order") ?? 0),
            createdAt: row.date("created_at") ?? Date(),
            lastActivityAt: row.date("last_activity_at") ?? Date(),
            archivedAt: row.date("archived_at"),
            additions: Int(row.int("additions") ?? 0),
            deletions: Int(row.int("deletions") ?? 0),
            changedFiles: Int(row.int("changed_files") ?? 0),
            unread: row.bool("unread"),
            pinned: row.bool("pinned"),
            colour: row.string("colour"),
            origin: WorkspaceOrigin(
                parentWorkspaceID: row.string("parent_workspace_id"),
                spawnToolUseID: row.string("spawn_tool_use_id")
            ),
            port: Int(row.int("port") ?? 0),
            pullRequestNumber: row.int("pull_request_number").map(Int.init),
            kind: WorkspaceKind(rawValue: row.string("kind") ?? "") ?? .worktree
        )
    }

    static func delivery(from row: Row) -> Delivery {
        Delivery(
            id: DeliveryID(row.string("id") ?? newID()),
            targetSessionID: SessionID(row.string("target_session_id") ?? ""),
            sourceWorkspaceID: row.string("source_workspace_id").map(WorkspaceID.init),
            // An unknown word is the owner's, because that is the only kind this app has ever
            // written and a row it cannot classify is still a sentence somebody is waiting on.
            kind: Delivery.Kind(rawValue: row.string("kind") ?? "") ?? .owner,
            verdict: row.string("verdict"),
            body: row.string("body") ?? "",
            crewPayload: row.data("crew_payload"),
            createdAt: row.date("created_at") ?? Date(),
            deliveredAt: row.date("delivered_at"),
            deliveredSeq: row.int("delivered_seq").map(Int.init),
            state: Delivery.State(rawValue: row.string("delivery_state") ?? ""),
            interactionMode: row.string("interaction_mode").flatMap(InteractionMode.init(rawValue:)),
            providerTurnID: row.string("provider_turn_id")
        )
    }

    static func workspaceMessage(from row: Row) -> WorkspaceMessage {
        WorkspaceMessage(
            stored: WorkspaceMessageID(row.string("id") ?? newID()),
            source: WorkspaceMessageEnd(
                workspaceID: row.string("source_workspace_id").map(WorkspaceID.init),
                workspace: row.string("source_workspace_name") ?? "",
                project: row.string("source_project_name") ?? "",
                sessionID: row.string("source_session_id").map(SessionID.init),
                chat: row.string("source_chat") ?? ""
            ),
            target: WorkspaceMessageEnd(
                workspaceID: row.string("target_workspace_id").map(WorkspaceID.init),
                workspace: row.string("target_workspace_name") ?? "",
                project: row.string("target_project_name") ?? "",
                sessionID: row.string("target_session_id").map(SessionID.init),
                chat: row.string("target_chat") ?? ""
            ),
            replySessionID: row.string("reply_session_id").map(SessionID.init),
            text: row.string("body") ?? "",
            deliveryID: row.string("delivery_id").map(DeliveryID.init),
            // A word this build does not know is read as cancelled, which offers nothing to press.
            state: WorkspaceMessage.State(rawValue: row.string("state") ?? "") ?? .cancelled,
            createdAt: row.date("created_at") ?? Date(),
            deliveredAt: row.date("delivered_at"),
            notifyWhenDone: (row.int("notify_when_done") ?? 0) != 0
        )
    }

    static func workspaceDoneWatch(from row: Row) -> WorkspaceDoneWatch {
        let cause: WorkspaceDoneWatch.Cause = if let messageID = row.string("message_id") {
            // A message row that has gone, or a state this build does not know, reads as
            // cancelled, which spends the watch with nothing said.
            .message(
                WorkspaceMessageID(messageID),
                state: WorkspaceMessage.State(rawValue: row.string("message_state") ?? "") ?? .cancelled
            )
        } else {
            .start
        }
        return WorkspaceDoneWatch(
            id: WorkspaceDoneWatchID(row.string("id") ?? newID()),
            cause: cause,
            watcherSessionID: SessionID(row.string("watcher_session_id") ?? ""),
            target: WorkspaceMessageEnd(
                workspaceID: row.string("target_workspace_id").map(WorkspaceID.init),
                workspace: row.string("target_workspace_name") ?? "",
                project: row.string("target_project_name") ?? "",
                sessionID: row.string("target_session_id").map(SessionID.init),
                chat: row.string("target_chat") ?? ""
            ),
            createdAt: row.date("created_at") ?? Date(),
            notifiedAt: row.date("notified_at")
        )
    }

    static func permissionGrant(from row: Row) -> PermissionGrant {
        let content = row.string("rule_content") ?? ""
        return PermissionGrant(
            id: PermissionGrantID(row.string("id") ?? newID()),
            repoID: RepoID(row.string("repo_id") ?? ""),
            toolName: row.string("tool_name") ?? "",
            // Stored as an empty string because SQLite counts every NULL as distinct in a unique
            // index, which would have let the same whole-tool grant be inserted over and over.
            ruleContent: content.isEmpty ? nil : content,
            grantedAt: row.date("granted_at") ?? Date(),
            lastUsedAt: row.date("last_used_at"),
            useCount: Int(row.int("use_count") ?? 0),
            grantedFor: row.string("granted_for") ?? ""
        )
    }

    /// Nil when the stored bytes will not decode. A row Bloom cannot read is a question it cannot
    /// draw, and skipping it is better than an ask with no command and four live buttons.
    static func pendingPermissionAsk(from row: Row) -> PendingPermissionAsk? {
        guard let id = row.string("id"),
              let payload = row.data("payload"),
              let ask = PermissionAsk.decode(payload: payload)
        else {
            return nil
        }
        return PendingPermissionAsk(
            requestID: id,
            sessionID: SessionID(row.string("session_id") ?? ""),
            ask: ask,
            askedAt: row.date("created_at") ?? Date()
        )
    }

    static func session(from row: Row) -> Session {
        Session(
            id: SessionID(row.string("id") ?? newID()),
            // A null here is a chat with no worktree, which is Ask Bloom. See `Session.workspaceID`.
            workspaceID: row.string("workspace_id").map(WorkspaceID.init),
            // A row written before the column existed has no parent, which is what it was: a chat
            // the owner made.
            parentSessionID: row.string("parent_session_id").map(SessionID.init),
            sideConversationParentID: row.string("side_conversation_parent_id").map(SessionID.init),
            title: row.string("title") ?? "Session",
            agentSessionID: row.string("agent_session_id"),
            model: row.string("model") ?? "opus",
            effort: row.string("effort") ?? "high",
            // A row written before the column existed reads as Claude Code, which is what it was.
            agentKind: AgentKind(rawValue: row.string("agent_kind") ?? "") ?? .claudeCode,
            permissionMode: PermissionMode(rawValue: row.string("permission_mode") ?? "") ?? .acceptEdits,
            interactionMode: InteractionMode(rawValue: row.string("interaction_mode") ?? "") ?? .build,
            state: SessionState(rawValue: row.string("state") ?? "idle") ?? .idle,
            sortOrder: Int(row.int("sort_order") ?? 0),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            archivedAt: row.date("archived_at"),
            lastReadSeq: Int(row.int("last_read_seq") ?? 0),
            inputTokens: Int(row.int("input_tokens") ?? 0),
            outputTokens: Int(row.int("output_tokens") ?? 0),
            costUSD: row.double("cost_usd") ?? 0,
            contextTokens: Int(row.int("context_tokens") ?? 0)
        )
    }

    static func quickPrompt(from row: Row) -> QuickPrompt {
        QuickPrompt(
            id: QuickPromptID(row.string("id") ?? newID()),
            name: row.string("name") ?? "",
            symbol: row.string("symbol") ?? QuickPrompt.defaultSymbol,
            text: row.string("text") ?? "",
            // A row read before the migration ran, or through a query that did not name the
            // column, has no value here at all, and no value means the prompt behaves the way it
            // always has. See `QuickPromptDelivery`.
            sendsImmediately: row.int("sends_immediately") == 1,
            opensNewChat: row.int("opens_new_chat") == 1,
            sortOrder: Int(row.int("sort_order") ?? 0),
            createdAt: row.date("created_at") ?? Date()
        )
    }

    static func reviewComment(from row: Row) -> ReviewComment {
        ReviewComment(
            id: ReviewCommentID(row.string("id") ?? newID()),
            workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
            filePath: row.string("file_path") ?? "",
            side: ReviewCommentSide(rawValue: row.string("side") ?? "") ?? .new,
            anchor: ReviewCommentAnchor(
                line: Int(row.int("line") ?? 1),
                text: row.string("line_text") ?? "",
                before: decodeContext(row.string("context_before")),
                after: decodeContext(row.string("context_after")),
                // A row written before ranges existed has no span at all, and one line is what it
                // meant. The initialiser floors it, so a nought or a negative left by anything
                // else reads as the single line it can only have been.
                span: Int(row.int("span") ?? 1)
            ),
            body: row.string("body") ?? "",
            createdAt: row.date("created_at") ?? Date(),
            isAttached: row.bool("attached")
        )
    }

    static func reviewedFile(from row: Row) -> ReviewedFile {
        ReviewedFile(
            workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
            path: row.string("file_path") ?? "",
            fingerprint: row.string("fingerprint") ?? "",
            viewedAt: row.date("viewed_at") ?? Date()
        )
    }

    /// JSON rather than newline-joined text. A context line is a line of source, so joining on
    /// newlines cannot tell an empty list from a list holding one empty line, and getting that
    /// wrong shifts every stored snippet by one.
    static func encodeContext(_ lines: [String]) -> String {
        guard let data = try? JSONEncoder().encode(lines) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeContext(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return lines
    }

    static func message(from row: Row) -> Message {
        Message(
            id: row.int("id") ?? 0,
            sessionID: SessionID(row.string("session_id") ?? ""),
            seq: Int(row.int("seq") ?? 0),
            kind: MessageKind(rawValue: row.string("kind") ?? "") ?? .system,
            payload: row.data("payload") ?? Data(),
            createdAt: row.date("created_at") ?? Date(),
            durationMS: row.int("duration_ms").map(Int.init),
            refID: row.string("ref_id")
        )
    }

    static func ocean(from row: Row) -> Ocean {
        Ocean(
            name: row.string("name") ?? "",
            slug: row.string("slug") ?? "",
            latitude: row.double("latitude") ?? 0,
            longitude: row.double("longitude") ?? 0,
            usedAt: row.date("used_at")
        )
    }
}
