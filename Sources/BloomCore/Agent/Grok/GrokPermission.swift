import Foundation
import BloomClient

/// Grok's `session/request_permission`, in the vocabulary Bloom's permission prompt already speaks.
///
/// ACP sends a tool call plus a list of options (`allow_once`, `allow_always`, `reject_once`,
/// `reject_always`). Bloom's prompt is allow once / session / project and deny, so the options
/// are matched onto that rather than drawn as a fourth UI. An `allow_always` option is what
/// makes the persistent grant available; without one, `suppressesAlwaysAllow` is set and the
/// prompt will not offer a rule Bloom could not honour on the wire.
public enum GrokPermission {
    public static func requestID(_ id: GrokRequestID, sessionID: String, connectionID: UUID) -> String {
        // RPC ids can restart at one when the same session resumes in a new process.
        "grok:\(connectionID.uuidString):\(sessionID):\(id.jsonLiteral)"
    }

    public static func ask(for request: GrokPermissionRequest, connectionID: UUID = UUID()) -> PermissionAsk {
        let name = GrokTranslation.toolName(for: request.toolCall)
        let input = GrokTranslation.input(for: request.toolCall)
        let allowsAlways = request.options.contains { $0.kind == "allow_always" }
        let ask = PermissionAsk(
            requestID: requestID(request.id, sessionID: request.sessionID, connectionID: connectionID),
            toolName: name,
            displayName: request.toolCall.title,
            toolUseID: request.toolCall.id,
            input: input,
            summary: request.toolCall.title,
            reason: "",
            reasonType: "permissionPromptTool",
            blockedPath: request.toolCall.path.isEmpty ? nil : request.toolCall.path,
            suggestions: allowsAlways ? [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                destination: PermissionDestination.session.rawValue,
                rules: [PermissionRule(toolName: name, ruleContent: ruleContent(for: request.toolCall))],
                raw: .object([:])
            )] : [],
            suppressesAlwaysAllow: !allowsAlways,
            raw: Data()
        )
        return ask.with(raw: envelope(for: ask))
    }

    public static func envelope(for ask: PermissionAsk) -> Data {
        let json = JSONValue.object(omittingNil: [
            "type": .string("control_request"),
            "request_id": .string(ask.requestID),
            "agent_kind": .string(AgentKind.grok.rawValue),
            "request": .object(omittingNil: [
                "subtype": .string("can_use_tool"),
                "tool_name": .string(ask.toolName),
                "display_name": ask.displayName.isEmpty ? nil : .string(ask.displayName),
                "tool_use_id": .string(ask.toolUseID),
                "input": ask.input,
                "description": .string(ask.summary),
                "decision_reason_type": .string(ask.reasonType),
                "blocked_path": ask.blockedPath.map(JSONValue.string),
                "suppress_always_allow_rule": .bool(ask.suppressesAlwaysAllow),
                "permission_suggestions": .array(ask.suggestions.map { suggestion in
                    .object([
                        "type": .string(suggestion.type),
                        "behavior": .string(suggestion.behavior),
                        "destination": .string(suggestion.destination),
                        "rules": .array(suggestion.rules.map { rule in
                            .object(omittingNil: [
                                "toolName": .string(rule.toolName),
                                "ruleContent": rule.ruleContent.map(JSONValue.string),
                            ])
                        }),
                    ])
                }),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    /// The option Bloom should send back for this decision, or nil when the agent did not offer
    /// one that means that. A missing option is answered as cancelled rather than as a guessed
    /// allow: inventing an `optionId` the agent did not list is how a deny becomes an allow.
    public static func optionID(for decision: PermissionDecision, in request: GrokPermissionRequest) -> String? {
        let wanted: [String]
        switch decision {
        case .allow(.once), .answer, .approvePlan:
            wanted = ["allow_once"]
        case .allow(.session), .allow(.project):
            wanted = ["allow_always", "allow_once"]
        case .deny(_, let endsTurn):
            wanted = endsTurn ? ["reject_always", "reject_once"] : ["reject_once", "reject_always"]
        }
        for kind in wanted {
            if let match = request.options.first(where: { $0.kind == kind }) {
                return match.id
            }
        }
        return request.options.first { decision.isAllow ? $0.isAllow : !$0.isAllow }?.id
    }

    public static func selectedResult(optionID: String) -> JSONValue {
        .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionID),
            ]),
        ])
    }

    public static let cancelledResult = JSONValue.object([
        "outcome": .object(["outcome": .string("cancelled")]),
    ])

    private static func ruleContent(for call: GrokToolCall) -> String? {
        let input = GrokTranslation.input(for: call)
        if let command = input["command"]?.stringValue, !command.isEmpty { return command }
        if !call.path.isEmpty { return call.path }
        return nil
    }
}
