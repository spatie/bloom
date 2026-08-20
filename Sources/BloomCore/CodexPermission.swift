import Foundation

/// Codex's five approval requests, in the vocabulary Bloom's permission prompt already speaks.
///
/// ## What is the same
///
/// The surfaces should feel like one app. So a Codex question becomes a `PermissionAsk`, lands in
/// the transcript where the call would have been, is stored in `permission_asks` so a workspace
/// reopened mid question can still draw it, and a project-wide allow is stored in Bloom's own
/// `permission_grants` keyed by repository and matched on exact equality. **No settings file is
/// written by anybody**, which is the same promise the Claude Code side makes.
///
/// ## What is different, and cannot be papered over
///
///   * **There is no rule grammar.** Claude Code's CLI sends `permission_suggestions`, its own
///     judgement about which rule would let this call and calls like it through. Codex sends
///     nothing of the kind. Bloom will not invent a pattern on its behalf, because a guessed rule
///     grants more than was approved. What it offers instead is the narrowest rule there is: the
///     command, verbatim, or the file path, verbatim. It cannot widen past the thing on screen,
///     and it will often not match again. That is the honest trade.
///   * **A refusal carries no sentence.** `decline` is a word, not a message, so
///     `PermissionDecision.deny(message:)`'s text has nowhere to go. The turn resumes and the
///     agent is told no, without being told why.
///   * **`acceptForSession` is remembered by the server, not by Bloom.** So "allow for this
///     session" costs Bloom nothing to keep, and dies with the app-server process rather than with
///     a stored row.
///   * Three of the five kinds have no rule shape at all (`permissions`, `mcpElicitation`,
///     `toolUserInput`), so those ask with the persistent option suppressed rather than offering a
///     grant nobody could describe.
public enum CodexPermission {
    /// The id an ask is filed under, which has to be a string and has to be unique in a session.
    ///
    /// Prefixed, because the server numbers its own requests from zero and restarts that numbering
    /// on every connection. A bare `0` would collide with the `0` of the connection before it, and
    /// `permission_asks` outlives the connection.
    public static func requestID(_ id: CodexRequestID, threadID: String) -> String {
        switch id {
        case .number(let value): "codex:\(threadID):\(value)"
        case .text(let value): "codex:\(threadID):\(value)"
        }
    }

    /// Build the question a person answers.
    ///
    /// `item` is the item the request is about, which the caller has because `item/started`
    /// arrived a moment earlier: the request itself carries only an id, so the diff or the command
    /// is not in it. Without the item the question is still asked, just with less on it.
    public static func ask(for request: CodexApprovalRequest, item: CodexItem?) -> PermissionAsk {
        let toolName = item.map(CodexTranslation.toolName(for:)) ?? fallbackToolName(request.kind)
        let input = item.map(CodexTranslation.input(for:)) ?? request.params
        let rule = rule(toolName: toolName, item: item, request: request)

        let ask = PermissionAsk(
            requestID: requestID(request.id, threadID: request.threadID),
            toolName: toolName,
            displayName: displayName(request.kind),
            toolUseID: request.itemID,
            input: input,
            summary: summary(for: request, item: item),
            reason: request.params["reason"]?.stringValue ?? "",
            reasonType: reasonType(request.kind),
            blockedPath: request.params["grantRoot"]?.stringValue,
            suggestions: rule.map { [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                destination: PermissionDestination.session.rawValue,
                rules: [$0],
                raw: .object([:])
            )] } ?? [],
            // No rule means no persistent option, which `canWiden` already enforces. Said twice on
            // purpose: the flag is the one the prompt reads, and it must not depend on the rules
            // array happening to be empty.
            suppressesAlwaysAllow: rule == nil,
            raw: Data()
        )
        // Rebuilt with its own bytes, because those bytes are what the database keeps and what a
        // workspace reopened mid question is redrawn from. The envelope has to be in the shape
        // `PermissionAsk.decode(payload:)` reads, which is a `control_request`, not a JSON-RPC
        // request: one vocabulary in the store, whichever backend wrote the row.
        return ask.with(raw: envelope(for: ask))
    }

    /// The stored form of a question. A faithful `can_use_tool` control request, carrying
    /// everything the ask holds, so decoding it gives the same value back.
    public static func envelope(for ask: PermissionAsk) -> Data {
        let json = JSONValue.object(omittingNil: [
            "type": .string("control_request"),
            "request_id": .string(ask.requestID),
            // Says which backend wrote this, for anything reading rows rather than events. The
            // decoder ignores it, which is the point: an extra member costs nothing.
            "agent_kind": .string(AgentKind.codex.rawValue),
            "request": .object(omittingNil: [
                "subtype": .string("can_use_tool"),
                "tool_name": .string(ask.toolName),
                "display_name": ask.displayName.isEmpty ? nil : .string(ask.displayName),
                "tool_use_id": .string(ask.toolUseID),
                "input": ask.input,
                "description": ask.summary.isEmpty ? nil : .string(ask.summary),
                "decision_reason": ask.reason.isEmpty ? nil : .string(ask.reason),
                "decision_reason_type": .string(ask.reasonType),
                "blocked_path": ask.blockedPath.map { .string($0) },
                "suppress_always_allow_rule": .bool(ask.suppressesAlwaysAllow),
                "requires_user_interaction": .bool(ask.requiresUserInteraction),
                "permission_suggestions": .array(ask.suggestions.map(suggestionJSON)),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    static func suggestionJSON(_ suggestion: PermissionSuggestion) -> JSONValue {
        .object([
            "type": .string(suggestion.type),
            "behavior": .string(suggestion.behavior),
            "destination": .string(suggestion.destination),
            "rules": .array(suggestion.rules.map { rule in
                .object(omittingNil: [
                    "toolName": .string(rule.toolName),
                    "ruleContent": rule.ruleContent.map { .string($0) },
                ])
            }),
        ])
    }

    /// The narrowest rule that would let this exact call through again, or nil when the kind has
    /// no shape Bloom can describe.
    static func rule(toolName: String, item: CodexItem?, request: CodexApprovalRequest) -> PermissionRule? {
        switch request.kind {
        case .commandExecution:
            let command = commandText(item: item, request: request)
            guard !command.isEmpty else { return nil }
            return PermissionRule(toolName: toolName, ruleContent: command)

        case .fileChange:
            guard case .fileChange(let change)? = item, let first = change.changes.first else {
                return nil
            }
            return PermissionRule(toolName: toolName, ruleContent: first.path)

        // A granted permission profile, an MCP form and a tool's own question. None of the three
        // is a rule, and two of them are answered with content rather than with a word.
        case .permissions, .mcpElicitation, .toolUserInput:
            return nil
        }
    }

    static func commandText(item: CodexItem?, request: CodexApprovalRequest) -> String {
        if case .commandExecution(let run)? = item, !run.command.isEmpty { return run.command }
        return request.command ?? ""
    }

    static func fallbackToolName(_ kind: CodexApprovalRequest.Kind) -> String {
        switch kind {
        case .commandExecution: "Shell"
        case .fileChange: "ApplyPatch"
        case .permissions: "Permissions"
        case .mcpElicitation: "McpElicitation"
        case .toolUserInput: "UserInput"
        }
    }

    static func displayName(_ kind: CodexApprovalRequest.Kind) -> String {
        switch kind {
        case .commandExecution: "Run a command"
        case .fileChange: "Change files"
        case .permissions: "Widen permissions"
        case .mcpElicitation: "Answer an MCP server"
        case .toolUserInput: "Answer a tool"
        }
    }

    /// The closed set `PermissionAsk.reasonType` documents has no Codex member, and the nearest
    /// truthful one is the same for all five: the sandbox stopped it and the policy says ask.
    static func reasonType(_ kind: CodexApprovalRequest.Kind) -> String {
        switch kind {
        case .commandExecution, .fileChange: "sandboxOverride"
        default: "other"
        }
    }

    static func summary(for request: CodexApprovalRequest, item: CodexItem?) -> String {
        switch request.kind {
        case .commandExecution:
            return commandText(item: item, request: request)
        case .fileChange:
            guard case .fileChange(let change)? = item else { return "Apply a patch" }
            let paths = change.changes.map(\.path)
            return paths.count == 1
                ? "\(change.changes[0].kind.label) \(paths[0])"
                : "\(paths.count) files"
        default:
            return displayName(request.kind)
        }
    }

    // MARK: - Answering

    /// What Bloom's answer becomes on the wire.
    ///
    /// Project scope sends `acceptForSession`, exactly as the Claude Code side does for the same
    /// case: the agent is told to stop asking for the rest of this session, Bloom keeps the durable
    /// record itself, and no configuration belonging to the user is touched.
    public static func decision(for decision: PermissionDecision) -> CodexApprovalDecision {
        switch decision {
        case .allow(.once): .accept
        case .allow(.session), .allow(.project): .acceptForSession
        case .deny(_, let endsTurn): endsTurn ? .cancel : .decline
        }
    }
}

// MARK: - Helpers

extension PermissionAsk {
    /// The same question carrying its own stored bytes. Only the payload changes.
    func with(raw: Data) -> PermissionAsk {
        var copy = self
        copy.raw = raw
        return copy
    }
}
