import Foundation

/// The chat the app created or closed, reduced to what the caller needs to identify it again.
public struct BridgeChatSummary: Sendable, Equatable {
    public let chatID: SessionID
    public let title: String
    public let agent: AgentKind
    public let model: String
    public let effort: String
    public let permissionMode: PermissionMode
    public let interactionMode: InteractionMode
    public let workspaceID: WorkspaceID
    public let workspace: String

    public init(
        chatID: SessionID,
        title: String,
        agent: AgentKind,
        model: String,
        effort: String,
        permissionMode: PermissionMode,
        interactionMode: InteractionMode,
        workspaceID: WorkspaceID,
        workspace: String
    ) {
        self.chatID = chatID
        self.title = title
        self.agent = agent
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.interactionMode = interactionMode
        self.workspaceID = workspaceID
        self.workspace = workspace
    }

    var json: JSONValue {
        .object([
            "chat_id": .string(chatID.rawValue),
            "link": .string(WorkspaceLink.address(workspace: workspaceID, chat: chatID)),
            "title": .string(title),
            "agent": .string(agent.rawValue),
            "model": .string(model),
            "effort": .string(effort),
            "permission_mode": .string(permissionMode.rawValue),
            "interaction_mode": .string(interactionMode.rawValue),
            "workspace_id": .string(workspaceID.rawValue),
            "workspace": .string(workspace),
        ])
    }
}

/// The choices the create-workspace composer can carry onto a new chat, with nil meaning that
/// project's current default. Branch, setup and checkout choices are workspace properties and do
/// not belong on a chat inside a worktree that already exists.
public struct ChatCreateOrder: Sendable, Equatable {
    public let title: String?
    public let agent: AgentKind?
    public let model: String?
    public let effort: String?
    public internal(set) var permissionMode: PermissionMode?
    public internal(set) var interactionMode: InteractionMode?
    public let fastMode: Bool?
    public let outputStyle: String?
    public let contextWindow: Int?
    public let terminalChat: Bool?
    /// Sent unwrapped, so a slash command in it runs as one.
    public let message: String?
    /// The chat that asked for `message`, shown above it. Nil for the owner's own client.
    public internal(set) var messageSender: String?
    /// The asking chat's agent, which says what its modes mean.
    public internal(set) var messageSenderAgent: AgentKind?

    public init(
        title: String? = nil,
        agent: AgentKind? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        interactionMode: InteractionMode? = nil,
        fastMode: Bool? = nil,
        outputStyle: String? = nil,
        contextWindow: Int? = nil,
        terminalChat: Bool? = nil,
        message: String? = nil,
        messageSender: String? = nil,
        messageSenderAgent: AgentKind? = nil
    ) {
        self.title = title
        self.agent = agent
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.interactionMode = interactionMode
        self.fastMode = fastMode
        self.outputStyle = outputStyle
        self.contextWindow = contextWindow
        self.terminalChat = terminalChat
        self.message = message
        self.messageSender = messageSender
        self.messageSenderAgent = messageSenderAgent
    }
}

extension ChatCreateOrder {
    /// An agent's message runs in its caller's modes on the new chat's agent. A caller that may not
    /// write stays so: Codex holds that as Plan or Read only (its `.auto`), the others as Plan.
    public func modes(on agent: AgentKind) -> (permission: PermissionMode?, interaction: InteractionMode?) {
        guard let sender = messageSenderAgent, sender != agent else { return (permissionMode, interactionMode) }
        let readOnly = permissionMode == .plan || interactionMode == .plan
            || (sender == .codex && permissionMode == .auto)
        if InteractionMode.supports(agent) {
            return (readOnly ? .auto : permissionMode?.nearest(on: agent), readOnly ? .plan : .build)
        }
        return (readOnly ? .plan : permissionMode?.nearest(on: agent), .build)
    }
}

/// What happened when the app was asked to add a chat to a workspace.
public enum ChatCreateOutcome: Sendable, Equatable {
    case created(BridgeChatSummary)
    case refused(String)
}

/// What happened when the app was asked to close a chat in a workspace.
public enum ChatCloseOutcome: Sendable, Equatable {
    case closed(BridgeChatSummary)
    case refused(String)
}

/// What happened when the app was asked to rename a chat.
public enum ChatRenameOutcome: Sendable, Equatable {
    case renamed(chat: BridgeChatSummary, previousTitle: String)
    case refused(String)
}

/// These cross into the app for the same reason as `CrewStarting`: the window owns the one runner
/// per session, the tab arrangement and the active chat. Writing the row from a bridge handler
/// would leave all three out of sync.
public typealias ChatCreating = @Sendable (WorkspaceID, ChatCreateOrder) async -> ChatCreateOutcome
public typealias ChatClosing = @Sendable (WorkspaceID, SessionID) async -> ChatCloseOutcome
public typealias ChatRenaming =
    @Sendable (WorkspaceID, SessionID, String) async -> ChatRenameOutcome

/// The two costs `chat_close` will not take without a person at the keyboard.
///
/// This is separate from `SessionClosure`, which decides when the app asks for confirmation.
/// A self-approved bridge call has nobody to ask, so it refuses instead. Leaving one chat behind
/// is also what makes the two calls a handover rather than a way to empty another workspace.
public enum BridgeChatClosure {
    public static func refusal(
        title: String,
        isRunning: Bool,
        otherTopLevelChats: Int
    ) -> String? {
        if isRunning {
            return """
                The chat '\(title)' is still working, so Bloom did not close it. Wait for the turn \
                to finish or stop it in the app.
                """
        }
        if otherTopLevelChats <= 0 {
            return """
                That is the workspace's last top-level chat. Call chat_create first, then close \
                this one.
                """
        }
        return nil
    }
}

/// `chat_create`: add a new top-level chat to this workspace or another one the caller names.
public struct ChatCreateTool: BridgeToolHandling {
    private let create: ChatCreating

    public init(_ create: @escaping ChatCreating) {
        self.create = create
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]
    public let tool = BridgeTool(
        name: "chat_create",
        description: """
            Add a new chat to a workspace. Leave its agent settings out to use that project's \
            current defaults, or pass the same choices the create-workspace composer offers: \
            agent, model, reasoning effort, permission mode, work mode, fast mode, output style \
            and Codex context window, plus whether the chat runs in a visible terminal. The new \
            chat becomes the workspace's active destination. \
            Pass 'message' to start a turn in the new chat with it, as though the owner had typed \
            it, so a slash command runs. Only in your own workspace, and only while no other \
            chat there is working, in your own permission and work modes, headed with your chat's name: a \
            message to another workspace goes through workspace_say. \
            A chat started with a message is never terminal-backed. \
            For a handover, close the old chat next.

            Without 'workspace' it adds the chat to your own workspace. Pass a workspace id from \
            workspace_list, or a name no other active workspace shares, to add it somewhere else. \
            A client that is not working in a workspace must pass it.

            'title' is optional. Leave it out for Bloom's own numbering, such as Chat or Chat 2. \
            This does not select another workspace or take the owner's window away from what they \
            are viewing.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                BridgeReadTarget.argument: workspaceProperty(verb: "add the chat to"),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("What to call the chat. Omit it for Bloom's own numbering."),
                ]),
                "agent": .object([
                    "type": .string("string"),
                    "enum": .array(AgentKind.runnable.map { .string($0.rawValue) }),
                    "description": .string(
                        "Which agent runs the chat. Omit it to infer the backend from model, or use the project's default."
                    ),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The exact model id. Omit it to use the selected agent's default model."
                    ),
                ]),
                "effort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The exact reasoning-effort id supported by the chosen model."
                    ),
                ]),
                "permission_mode": .object([
                    "type": .string("string"),
                    "enum": .array(PermissionMode.allCases.map { .string($0.rawValue) }),
                    "description": .string("How much the chat may do without asking."),
                ]),
                "interaction_mode": .object([
                    "type": .string("string"),
                    "enum": .array(InteractionMode.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "Build or plan. Plan is supported only by Codex; other agents use build."
                    ),
                ]),
                "fast_mode": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Whether to use the chosen agent's faster mode. Omit it to keep the project default."
                    ),
                ]),
                "output_style": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Claude Code output-style name. Omit it for the project default."
                    ),
                ]),
                "context_window": .object([
                    "type": .string("integer"),
                    "enum": .array(CodexContextWindow.choices.map { .integer($0) }),
                    "description": .string(
                        "Codex context window in tokens: 0 for the model default, 500000 or 1000000."
                    ),
                ]),
                "terminal_chat": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Whether to run the agent in a visible terminal-backed chat. Omit it to use the app default."
                    ),
                ]),
                "message": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The first message, which starts a turn in the new chat. Your own workspace only."
                    ),
                ]),
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        var order: ChatCreateOrder
        switch Self.order(from: request) {
        case .failure(let refusal): return .failure(refusal.sentence)
        case .success(let parsed): order = parsed
        }

        do {
            let target: BridgeReadTarget
            switch try await BridgeReadTarget.resolve(request, as: identity, store: store) {
            case .failure(let trouble):
                return .failure(trouble.sentence(tool: "chat_create", workspacePurpose: "add a chat to"))
            case .success(let resolved):
                target = resolved
            }
            let workspaceID = target.workspaceID
            if order.message != nil, identity.role != .owner {
                let sessions = try await store.sessions(workspaceID: workspaceID)
                switch Self.messageOrder(order, from: identity, into: workspaceID, among: sessions) {
                case .failure(let refusal): return .failure(refusal.sentence)
                case .success(let headed): order = headed
                }
            }

            switch await create(workspaceID, order) {
            case .created(let summary):
                return .json(summary.json)
            case .refused(let refusal):
                return .failure(refusal)
            }
        } catch {
            return .failure("Bloom could not create the chat: \(error.localizedDescription)")
        }
    }

    /// A self-approved turn needs brakes, as `agent_start` and `workspace_say` have: the caller's
    /// own workspace, permission mode and work mode, and one working chat beside it at a time, so a handover
    /// passes and a fan-out or an escalation does not.
    static func messageOrder(
        _ order: ChatCreateOrder, from identity: BridgeIdentity, into workspaceID: WorkspaceID, among sessions: [Session]
    ) -> Result<ChatCreateOrder, PaneRefusal> {
        guard workspaceID == identity.workspaceID else {
            return .failure(PaneRefusal(
                "chat_create sends a 'message' only in your own workspace. Create the chat without it, then use workspace_say."
            ))
        }
        guard let caller = sessions.first(where: { $0.id == identity.sessionID }) else {
            return .failure(PaneRefusal("Bloom no longer has the chat asking, so it started no turn for it."))
        }
        if let asked = order.permissionMode, asked != caller.permissionMode {
            return .failure(PaneRefusal(
                "With a 'message', the new chat runs in your own permission mode, "
                    + "'\(caller.permissionMode.rawValue)'. Leave 'permission_mode' out."
            ))
        }
        if let asked = order.interactionMode, asked != caller.interactionMode {
            return .failure(PaneRefusal(
                "With a 'message', the new chat runs in your own work mode, "
                    + "'\(caller.interactionMode.rawValue)'. Leave 'interaction_mode' out."
            ))
        }
        let busy = sessions.contains {
            $0.id != caller.id && $0.parentSessionID == nil && $0.sideConversationParentID == nil && $0.state.isMidTurn
        }
        guard !busy else {
            return .failure(PaneRefusal(
                "Another chat in this workspace is working or waiting for an answer, so chat_create did "
                    + "not start a turn in a new one. Wait for it to finish, or create the chat without 'message'."
            ))
        }
        var headed = order
        headed.permissionMode = caller.permissionMode
        headed.interactionMode = caller.interactionMode
        headed.messageSender = ChatListTool.title(of: caller)
        headed.messageSenderAgent = caller.agentKind
        return .success(headed)
    }

    private static func order(from request: MCPRequest) -> Result<ChatCreateOrder, PaneRefusal> {
        let title: String?
        switch text(request, key: "title") {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): title = value
        }
        let model: String?
        switch text(request, key: "model") {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): model = value
        }
        let effort: String?
        switch text(request, key: "effort") {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): effort = value
        }
        let outputStyle: String?
        switch text(request, key: "output_style") {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): outputStyle = value
        }
        let message: String?
        switch text(request, key: "message") {
        case .failure where request.stringParam("message") != nil:
            return .failure(PaneRefusal("'message' cannot be blank. Leave it out to send nothing."))
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): message = value
        }
        if let message, message.count > WorkspaceSayTool.maximumLength {
            return .failure(PaneRefusal(
                "'message' is \(message.count) characters and chat_create takes up to "
                    + "\(WorkspaceSayTool.maximumLength)."
            ))
        }

        var agent: AgentKind?
        if let raw = request.param("agent"), raw != .null {
            guard let value = raw.stringValue, let kind = AgentKind(rawValue: value), kind.canRunWorkspaces else {
                return .failure(PaneRefusal(
                    "Bloom cannot run that agent. It runs \(AgentKind.runnable.map(\.rawValue).joined(separator: ", "))."
                ))
            }
            agent = kind
        }

        var permissionMode: PermissionMode?
        if let raw = request.param("permission_mode"), raw != .null {
            guard let value = raw.stringValue, let mode = PermissionMode(rawValue: value) else {
                return .failure(PaneRefusal("'permission_mode' is not one of Bloom's permission modes."))
            }
            permissionMode = mode
        }

        var interactionMode: InteractionMode?
        if let raw = request.param("interaction_mode"), raw != .null {
            guard let value = raw.stringValue, let mode = InteractionMode(rawValue: value) else {
                return .failure(PaneRefusal("'interaction_mode' must be 'build' or 'plan'."))
            }
            interactionMode = mode
        }

        let fastMode: Bool?
        switch request.param("fast_mode") {
        case nil, .null: fastMode = nil
        case .bool(let value): fastMode = value
        default: return .failure(PaneRefusal("'fast_mode' must be true or false."))
        }

        let contextWindow: Int?
        switch request.param("context_window") {
        case nil, .null: contextWindow = nil
        case .integer(let value) where CodexContextWindow.choices.contains(value):
            contextWindow = value
        default:
            return .failure(PaneRefusal(
                "'context_window' must be 0, 500000 or 1000000."
            ))
        }

        let terminalChat: Bool?
        switch request.param("terminal_chat") {
        case nil, .null: terminalChat = nil
        case .bool(let value): terminalChat = value
        default: return .failure(PaneRefusal("'terminal_chat' must be true or false."))
        }
        // A terminal chat reads as idle until its process is polled, which the brake cannot see.
        if message != nil, terminalChat == true {
            return .failure(PaneRefusal("'message' starts a turn in Bloom's own chat, so leave 'terminal_chat' out."))
        }

        return .success(ChatCreateOrder(
            title: title,
            agent: agent,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            interactionMode: interactionMode,
            fastMode: fastMode,
            outputStyle: outputStyle,
            contextWindow: contextWindow,
            terminalChat: terminalChat,
            message: message
        ))
    }

    private static func text(
        _ request: MCPRequest, key: String
    ) -> Result<String?, PaneRefusal> {
        guard let raw = request.param(key), raw != .null else { return .success(nil) }
        guard let value = raw.stringValue else {
            return .failure(PaneRefusal("'\(key)' must be text."))
        }
        guard let filled = PaneOrder.name(from: value) else {
            return .failure(PaneRefusal("Leave '\(key)' out to use Bloom's default."))
        }
        return .success(filled)
    }
}

/// `chat_close`: close an idle top-level chat while preserving it in Recently Closed.
public struct ChatCloseTool: BridgeToolHandling {
    private let close: ChatClosing

    public init(_ close: @escaping ChatClosing) {
        self.close = close
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]
    public let tool = BridgeTool(
        name: "chat_close",
        description: """
            Close an existing chat in a workspace by its id or exact title. The transcript is not \
            deleted: Bloom keeps it in Recently Closed, where the owner can restore it.

            Without 'workspace' it closes a chat in your own workspace. Pass a workspace id from \
            workspace_list, or a name no other active workspace shares, to close one somewhere \
            else. A client that is not working in a workspace must pass it. Use chat_list with the \
            same workspace to discover chat ids and disambiguate shared titles.

            It refuses a chat whose agent is working and refuses the workspace's last top-level \
            chat. For a handover, call chat_create first, then close the old chat. Subagent chats \
            are managed with agent_stop instead.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                BridgeReadTarget.argument: workspaceProperty(verb: "close the chat in"),
                "chat": .object([
                    "type": .string("string"),
                    "description": .string("Chat id or exact title. Use chat_list to discover ids."),
                ]),
            ]),
            "required": .array([.string("chat")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let chat = request.stringParam("chat"),
              !chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Pass a chat ID or exact title from chat_list as 'chat'.")
        }

        do {
            let target: BridgeReadTarget
            switch try await BridgeReadTarget.resolve(request, as: identity, store: store) {
            case .failure(let trouble):
                return .failure(trouble.sentence(tool: "chat_close", workspacePurpose: "close a chat in"))
            case .success(let resolved):
                target = resolved
            }
            let workspaceID = target.workspaceID

            let sessions = try await store.sessions(workspaceID: workspaceID)
            let session: Session
            switch selectTopLevelChat(chat, from: sessions, in: target) {
            case .found(let found): session = found
            case .refused(let refusal): return .failure(refusal)
            }

            switch await close(workspaceID, session.id) {
            case .closed(let summary):
                return .json(summary.json)
            case .refused(let refusal):
                return .failure(refusal)
            }
        } catch {
            return .failure("Bloom could not close the chat: \(error.localizedDescription)")
        }
    }
}

/// `chat_rename`: rename a top-level chat in this workspace or another one the caller names.
public struct ChatRenameTool: BridgeToolHandling {
    private let rename: ChatRenaming

    public init(_ rename: @escaping ChatRenaming) {
        self.rename = rename
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]
    public let tool = BridgeTool(
        name: "chat_rename",
        description: """
            Rename an existing top-level chat in a workspace by its id or exact title. Use \
            chat_list with the same workspace to discover chat ids and disambiguate shared titles.

            Without 'workspace' it renames a chat in your own workspace. Pass a workspace id from \
            workspace_list, or a name no other active workspace shares, to rename one somewhere \
            else. A client that is not working in a workspace must pass it. Subagent chats are \
            managed by their orchestrator and are not renamed here.

            The answer includes the previous title, so renaming it back costs one more call.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                BridgeReadTarget.argument: workspaceProperty(verb: "rename the chat in"),
                "chat": .object([
                    "type": .string("string"),
                    "description": .string("Chat id or exact title. Use chat_list to discover ids."),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("The chat's new title."),
                ]),
            ]),
            "required": .array([.string("chat"), .string("title")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let chat = PaneOrder.name(from: request.stringParam("chat")) else {
            return .failure("Pass a chat ID or exact title from chat_list as 'chat'.")
        }
        guard let title = PaneOrder.name(from: request.stringParam("title")) else {
            return .failure("chat_rename needs a non-blank 'title'.")
        }

        do {
            let target: BridgeReadTarget
            switch try await BridgeReadTarget.resolve(request, as: identity, store: store) {
            case .failure(let trouble):
                return .failure(trouble.sentence(tool: "chat_rename", workspacePurpose: "rename a chat in"))
            case .success(let resolved):
                target = resolved
            }
            let workspaceID = target.workspaceID

            let sessions = try await store.sessions(workspaceID: workspaceID)
            let session: Session
            switch selectTopLevelChat(chat, from: sessions, in: target) {
            case .found(let found): session = found
            case .refused(let refusal): return .failure(refusal)
            }

            switch await rename(workspaceID, session.id, title) {
            case let .renamed(summary, previousTitle):
                var answer = summary.json.objectValue ?? [:]
                answer["previous_title"] = .string(previousTitle)
                return .json(.object(answer))
            case .refused(let refusal):
                return .failure(refusal)
            }
        } catch {
            return .failure("Bloom could not rename the chat: \(error.localizedDescription)")
        }
    }
}

private enum TopLevelChatSelection {
    case found(Session)
    case refused(String)
}

private func selectTopLevelChat(
    _ selector: String,
    from sessions: [Session],
    in target: BridgeReadTarget
) -> TopLevelChatSelection {
    let topLevel = sessions.filter {
        $0.parentSessionID == nil && $0.sideConversationParentID == nil
    }
    let byID = topLevel.filter { $0.id.rawValue == selector }
    let matches = byID.isEmpty
        ? topLevel.filter { ChatListTool.title(of: $0) == selector }
        : byID
    guard matches.count == 1, let session = matches.first else {
        if matches.count > 1 {
            return .refused("More than one chat has that title. Call chat_list and pass the chat's ID.")
        }
        return .refused(
            "No top-level chat with that ID or title is open in \(place(target)). "
                + "Call chat_list with the same workspace to see its chats."
        )
    }
    return .found(session)
}

private func workspaceProperty(verb: String) -> JSONValue {
    .object([
        "type": .string("string"),
        "description": .string(
            "The workspace to \(verb), by the id workspace_list reports, or by its name when no "
                + "other active workspace shares it. Leave it out for your own workspace. Required "
                + "from a client that is not working in a workspace."
        ),
    ])
}

private func place(_ target: BridgeReadTarget) -> String {
    switch target {
    case .own: "your workspace"
    case .named(let workspace): "the workspace '\(workspace.name)'"
    }
}
