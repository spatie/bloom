import Foundation

/// What happened when the app was asked to put a message in a chat.
public enum WorkspaceMessageDeliveryOutcome: Sendable, Equatable {
    /// It is in a chat's queue, or already handed over. The row as it stands after the drain.
    case sent(WorkspaceMessage)
    /// The app would not deliver it, in its own words.
    case refused(String)
}

/// Put a message in a chat in the target workspace, and start the turn.
///
/// A closure for the reason `CrewSaying` is one: which chat is active, and the runner that drains
/// a queue, are held on the main actor and nowhere else. Everything that decides whether the
/// message may go, and what it says, has been decided in the core before this is reached; the far
/// side picks a chat, calls `Store.enqueueWorkspaceMessage` and drains.
public typealias WorkspaceMessageDelivering =
    @Sendable (WorkspaceMessage) async -> WorkspaceMessageDeliveryOutcome

/// `workspace_say`: say something to the agent in another workspace.
///
/// ## Two callers, one tool
///
/// **The owner's own client** names a workspace out loud, as it does for everything, and may write
/// to any of them. **A workspace agent** does the same, which is the widening this tool exists
/// for, because talking to another workspace is the whole subject.
///
/// A workspace another agent started used to be narrowed to the workspace that started it and to
/// any that had written to it. That narrowing went with the child role, for the reasons
/// `BridgeRole` gives; the brake on two agents answering each other for ever is
/// `WorkspaceSayThrottle`, and it applies to every agent alike.
///
/// ## Why it is self-approved
///
/// What it costs is a turn in a chat the owner can see arriving, queued, with a way to take it
/// back out, which is the weight of `agent_say` one workspace further out. An ask in front of it
/// would hang a turn that may be running with nobody watching. See `BridgeToolApproval`.
///
/// ## What it does not do
///
/// It does not wait for an answer and there is no way to. An answer is a `workspace_say` of the
/// other agent's own, and it lands in the chat that sent this, because `replySessionID` remembers
/// which chat last wrote from there.
public struct WorkspaceSayTool: BridgeToolHandling {
    public static let name = "workspace_say"

    /// The longest message it takes. A message is drawn whole in two chats, so this is a bound on
    /// what is put in front of a person as much as on what goes to a model.
    public static let maximumLength = 20_000

    private let deliver: WorkspaceMessageDelivering

    public init(_ deliver: @escaping WorkspaceMessageDelivering) {
        self.deliver = deliver
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: WorkspaceSayTool.name,
        description: """
            Send a message to the agent in another Bloom workspace. It lands in that workspace's \
            chat and starts a turn there, the way agent_say does for a subagent in your own \
            workspace, or waits for the turn that is running.

            Name the workspace by the id workspace_list or workspace_start reports, or by its name \
            when no other workspace shares it. To answer a message that reached you from another \
            workspace, pass the id it names: your answer goes to the chat there that most recently \
            wrote to you.

            The message arrives with the owner's authority, headed with the workspace, project and \
            chat it came from, so the agent there may act on it as though the owner had typed it: \
            "fix the bug, merge the pull request, tag a release, then tell me the version with \
            workspace_say" is a message it will carry out. Write it as a message to that agent. It \
            cannot see this conversation.

            While it is queued, the owner can delete it from the chat it was sent to. If they do, \
            Bloom tells you here.

            It returns once the message is in that chat. It does not wait for an answer and there \
            is no way to wait for one from here, so say what you sent and get on with your own \
            work. An answer arrives in this chat as a message of its own.

            Pass notify_when_done: true to have Bloom tell this chat once, by itself, when the \
            turn your message causes there comes to rest: finished (with that agent's last \
            message), failed (with the reason), or blocked waiting on the owner for a permission \
            prompt or a question. With it, there is no need to ask the other agent to report \
            back when it is done.

            Bloom refuses a message identical to one you sent the same workspace in the last \
            \(Int(WorkspaceSayThrottle.window / 60)) minutes, and more than \
            \(WorkspaceSayThrottle.limit) messages to the same workspace in that time. Do not \
            thank or acknowledge an answer with another message: that starts a turn there for \
            nothing.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The workspace to send it to, by the id workspace_list reports, or by its "
                            + "name when no other workspace shares it. To answer a message, the "
                            + "id it names."
                    ),
                ]),
                "message": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What to say, written to that agent. It cannot see this conversation."
                    ),
                ]),
                WorkspaceDoneWatch.argument: .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Have Bloom tell this chat once when the turn this message causes there "
                            + "comes to rest: finished, failed, or waiting on the owner. Defaults "
                            + "to false."
                    ),
                ]),
            ]),
            "required": .array([.string("workspace"), .string("message")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let text = AgentStartTool.text(request.stringParam("message")) else {
            return .failure(WorkspaceSayTrouble.noMessage.sentence)
        }
        guard text.count <= Self.maximumLength else {
            return .failure(WorkspaceSayTrouble.tooLong(count: text.count).sentence)
        }
        guard let given = AgentStartTool.text(request.stringParam("workspace")) else {
            return .failure(WorkspaceSayTrouble.noWorkspace.sentence)
        }

        do {
            let sender = try await Sender.resolve(identity, store: store)
            // A token that names a workspace whose row has gone is refused rather than read as the
            // owner's own client, which is what a nil workspace would otherwise be taken for.
            if identity.workspaceID != nil, sender.workspace == nil {
                return .failure(WorkspaceSayTrouble.callerHasGone.sentence)
            }

            let target: Workspace
            switch try await Self.target(named: given, store: store) {
            case .failure(let trouble): return .failure(trouble.sentence)
            case .success(let found): target = found
            }

            if let source = sender.workspace, source.id == target.id {
                return .failure(WorkspaceSayTrouble.toItself.sentence)
            }

            // The brake on two agents answering each other for ever. The owner's own client is
            // exempt: a person is typing there, and a person repeating themselves means it.
            if identity.role != .owner, let source = sender.workspace {
                let now = Date()
                let recent = try await store.workspaceMessages(
                    from: source.id, to: target.id, since: now.addingTimeInterval(-WorkspaceSayThrottle.window)
                )
                if let trouble = WorkspaceSayThrottle.refusal(
                    sending: text, to: target.name, recent: recent, now: now
                ) {
                    return .failure(trouble.sentence)
                }
            }

            // Which chat an answer goes to: the one that last wrote to this workspace from there.
            var heard: WorkspaceMessage?
            if let source = sender.workspace {
                heard = try await store.latestWorkspaceMessage(from: target.id, to: source.id)
            }

            // Asked for, and possible: there has to be a chat to tell. The owner's own client has
            // none, so the flag is dropped and the answer says so rather than refusing a message
            // the owner meant to send.
            let wantsNotice = WorkspaceDoneWatch.isRequested(request.param(WorkspaceDoneWatch.argument))
            let sendEnd = sender.end

            let projectName = try await store.repo(id: target.repoID)?.name ?? ""
            let message = WorkspaceMessage(
                source: sendEnd,
                target: WorkspaceMessageEnd(
                    workspaceID: target.id, workspace: target.name, project: projectName
                ),
                replySessionID: heard?.source.sessionID,
                text: text,
                notifyWhenDone: wantsNotice && sendEnd.sessionID != nil
            )

            switch await deliver(message) {
            case .refused(let sentence):
                return .failure(WorkspaceSayTrouble.appRefused(sentence).sentence)
            case .sent(let sent):
                return .json(Self.answer(sent, noticeRequested: wantsNotice))
            }
        } catch {
            return .failure(WorkspaceSayTrouble.unexplained(error.readableMessage).sentence)
        }
    }

    // MARK: - Who is writing, and to whom

    /// The caller's own workspace, project and chat, or none of them for the owner's own client.
    struct Sender {
        var workspace: Workspace?
        var project: Repo?
        var session: Session?

        var end: WorkspaceMessageEnd {
            guard let workspace else { return .ownerClient }
            return WorkspaceMessageEnd(
                workspaceID: workspace.id,
                workspace: workspace.name,
                project: project?.name ?? "",
                sessionID: session?.id,
                chat: session?.title ?? ""
            )
        }

        static func resolve(_ identity: BridgeIdentity, store: Store) async throws -> Sender {
            var sender = Sender()
            if let workspaceID = identity.workspaceID {
                sender.workspace = try await store.workspace(id: workspaceID)
            }
            if let repoID = sender.workspace?.repoID {
                sender.project = try await store.repo(id: repoID)
            }
            if let sessionID = identity.sessionID {
                sender.session = try await store.session(id: sessionID)
            }
            return sender
        }
    }

    /// The active workspace a name means, or why there is none.
    ///
    /// Archived workspaces are looked through as well, only to say so: a workspace archived since
    /// the caller last listed them is a better refusal than "no such workspace".
    static func target(
        named given: String, store: Store
    ) async throws -> Result<Workspace, WorkspaceSayTrouble> {
        let all = try await store.workspaces(includeArchived: true)
        let active = all.filter { $0.state != .archived }

        switch BridgeWorkspaceLookup.find(given, among: active) {
        case .found(let workspace):
            return .success(workspace)
        case .ambiguous(let matches):
            return .failure(.ambiguous(given: given, ids: matches.map(\.id.rawValue)))
        case .unknown:
            if case .found(let archived) = BridgeWorkspaceLookup.find(given, among: all) {
                return .failure(.archived(name: archived.name))
            }
            return .failure(.unknown(given: given, known: active.map(\.name)))
        }
    }

    // MARK: - What the caller is told

    /// The answer, which is also what the sending chat's transcript reads back to draw the call as
    /// a message. `WorkspaceSayRecord` is the reader; the keys are written in both places from
    /// `Key`, so the two cannot drift.
    enum Key {
        static let state = "state"
        static let messageID = "message_id"
        static let workspaceID = "workspace_id"
        static let workspace = "workspace"
        static let project = "project"
        static let chat = "chat"
        static let note = "note"
        static let notifyWhenDone = WorkspaceDoneWatch.argument
    }

    static func answer(_ message: WorkspaceMessage, noticeRequested: Bool = false) -> JSONValue {
        let reply = message.source.workspaceID == nil
            ? "This connection is not a workspace, so the agent there cannot answer you with "
                + "workspace_say. Call workspace_list to see what became of it."
            : "If it answers, it answers with workspace_say, and its message lands in this chat, "
                + "unless another chat in this workspace writes to it before it does."
        let notice = if message.notifyWhenDone {
            " Bloom will tell this chat once, by itself, when the turn this message causes there "
                + "comes to rest: finished, failed, or waiting on the owner."
        } else if noticeRequested {
            " notify_when_done was ignored: this connection is not a chat in a Bloom workspace, so "
                + "there is nowhere to deliver the notice."
        } else {
            ""
        }
        let chat = message.target.chat
        return .object([
            Key.state: .string(message.state.rawValue),
            Key.messageID: .string(message.id.rawValue),
            Key.workspaceID: message.target.workspaceID.map { .string($0.rawValue) } ?? .null,
            Key.workspace: .string(message.target.workspace),
            Key.project: .string(message.target.project),
            Key.chat: .string(chat),
            Key.notifyWhenDone: .bool(message.notifyWhenDone),
            Key.note: .string(
                "Sent to the chat '\(chat)' in '\(message.target.workspace)', with the owner's "
                    + "authority. It starts a turn there, or waits for the one that is running, "
                    + "and the owner can delete it there while it waits. Bloom does not wait for "
                    + "an answer, so get on with your own work. " + reply + notice
            ),
        ])
    }
}

/// A `workspace_say` call read back out of a transcript, for the sending chat to draw as a message.
///
/// Built from the call's own input and the answer the tool gave, so nothing has to be written into
/// the sending chat beside the call itself: the call is the record. What became of the message
/// after that is read from the store by `messageID`, because the answer only knows the moment it
/// was sent.
public struct WorkspaceSayRecord: Sendable, Hashable {
    public let messageID: WorkspaceMessageID
    public let text: String
    public let target: WorkspaceMessageEnd

    /// Nil for any other tool, and for a call that was refused, which has no message to draw.
    public init?(toolName: String, input: JSONValue, resultText: String) {
        guard Self.isWorkspaceSay(toolName),
              let text = input["message"]?.stringValue,
              let answer = JSONValue.parse(resultText),
              let id = answer[WorkspaceSayTool.Key.messageID]?.stringValue
        else { return nil }

        messageID = WorkspaceMessageID(id)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        target = WorkspaceMessageEnd(
            workspaceID: answer[WorkspaceSayTool.Key.workspaceID]?.stringValue.map(WorkspaceID.init),
            workspace: answer[WorkspaceSayTool.Key.workspace]?.stringValue ?? "",
            project: answer[WorkspaceSayTool.Key.project]?.stringValue ?? "",
            chat: answer[WorkspaceSayTool.Key.chat]?.stringValue ?? ""
        )
    }

    /// Either bridge's spelling. The workspace bridge and the owner's own registration are served
    /// under different names, and the tool is the same tool under both.
    public static func isWorkspaceSay(_ toolName: String) -> Bool {
        toolName.hasPrefix("mcp__") && toolName.hasSuffix("__\(WorkspaceSayTool.name)")
    }
}

/// Why `workspace_say` would not send, in terms a model can act on.
public enum WorkspaceSayTrouble: Error, Sendable, Equatable {
    case noMessage
    case tooLong(count: Int)
    case noWorkspace
    case unknown(given: String, known: [String])
    case ambiguous(given: String, ids: [String])
    case archived(name: String)
    case toItself
    case callerHasGone
    /// The same words, to the same workspace, inside the window. See `WorkspaceSayThrottle`.
    case repeated(workspace: String)
    /// Too many messages to the same workspace inside the window.
    case tooMany(workspace: String, count: Int)
    case appRefused(String)
    case unexplained(String)

    public var sentence: String {
        switch self {
        case .noMessage:
            return "workspace_say needs a 'message' to send and it cannot be blank."

        case .tooLong(let count):
            return """
                That message is \(count) characters and workspace_say takes up to \
                \(WorkspaceSayTool.maximumLength). Send the other agent what it needs to act on, \
                and point it at files in its own worktree for the rest.
                """

        case .noWorkspace:
            return """
                workspace_say needs the 'workspace' to send it to. Call workspace_list and pass the \
                id it reports, or pass the id named in the message you are answering.
                """

        case let .unknown(given, known):
            return """
                Bloom has no active workspace called '\(given)'. Active workspaces: \
                \(BridgeWorkspaceLookup.list(known)). Retrying with the same name will fail the \
                same way, so pass an id workspace_list reports.
                """

        case let .ambiguous(given, ids):
            return """
                More than one workspace is called '\(given)', so Bloom will not guess which you \
                meant. Pass one of these ids instead: \(BridgeWorkspaceLookup.list(ids)).
                """

        case .archived(let name):
            return """
                The workspace '\(name)' has been archived, so there is no agent there to send it \
                to. Retrying will not change that.
                """

        case .toItself:
            return """
                That is the workspace you are in. workspace_say is for another workspace; to talk \
                to a subagent in this one, use agent_say.
                """

        case .callerHasGone:
            return """
                Bloom no longer has the workspace this connection speaks for, so it cannot say \
                where a message from it came from. Its row has gone, which retrying will not undo.
                """

        case .repeated(let workspace):
            return """
                You already sent exactly that message to '\(workspace)' in the last \
                \(Int(WorkspaceSayThrottle.window / 60)) minutes, and it arrived, so Bloom did not \
                send it again. Do not retry. Wait for the answer, which lands in this chat, or tell \
                the owner if you are stuck.
                """

        case let .tooMany(workspace, count):
            return """
                You have sent \(count) messages to '\(workspace)' in the last \
                \(Int(WorkspaceSayThrottle.window / 60)) minutes, which is as many as Bloom lets one \
                workspace send another, so this one was not sent. Two agents answering each other \
                is a loop that spends a turn on both sides every round. Do not retry and do not \
                acknowledge: wait for the answer you are owed, or tell the owner what you need.
                """

        case .appRefused(let sentence):
            return "Bloom did not deliver it: \(sentence)"

        case .unexplained(let message):
            return "Bloom could not complete workspace_say: \(message)"
        }
    }
}
