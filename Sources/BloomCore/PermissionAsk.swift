import Foundation

// MARK: - PermissionRule

/// One rule out of a permission suggestion, in the CLI's own vocabulary.
///
/// `ruleContent` is the CLI's, never Bloom's. A rule for one shell command comes back as
/// `Bash` + `sudo -n true`, and a rule for a family of them as `Bash` + `bin/test:*`; which of
/// those the CLI thinks is right is a judgement Bloom is in no position to second-guess, so it is
/// carried verbatim and compared verbatim. A rule with no content at all is the whole tool.
public struct PermissionRule: Sendable, Hashable, Codable {
    public var toolName: String
    public var ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }

    /// How the CLI itself spells this rule in a settings file, and therefore the only spelling
    /// worth showing a person. Verified against the file the CLI wrote unprompted during a live
    /// run: a suggestion of `Bash` + `sudo -n true` became `"Bash(sudo -n true)"`.
    public var displayText: String {
        guard let ruleContent, !ruleContent.isEmpty else { return toolName }
        return "\(toolName)(\(ruleContent))"
    }

    /// Whether this rule covers every use of its tool. Worth knowing separately because it is the
    /// broadest thing a single button can grant, and the ask carries a flag asking Bloom not to
    /// offer exactly that. See `PermissionAsk.suppressesAlwaysAllow`.
    public var isWholeTool: Bool { ruleContent?.isEmpty ?? true }

    public static func decode(_ json: JSONValue) -> PermissionRule? {
        guard let toolName = json["toolName"]?.stringValue, !toolName.isEmpty else { return nil }
        return PermissionRule(toolName: toolName, ruleContent: json["ruleContent"]?.stringValue)
    }
}

// MARK: - PermissionSuggestion

/// One entry of `permission_suggestions`, kept whole.
///
/// The CLI's schema for these has six shapes (`addRules`, `replaceRules`, `removeRules`,
/// `setMode`, `addDirectories`, `removeDirectories`) and only the first is one Bloom knows how to
/// describe in a sentence. Rather than model all six and risk dropping a field on the way back
/// out, the original JSON travels with the decoded view and is what gets echoed to the CLI. What
/// Bloom sends is then the CLI's own words, which is the only way to be sure Bloom never widens a
/// scope it was not offered.
public struct PermissionSuggestion: Sendable, Hashable {
    public var type: String
    public var behavior: String
    public var destination: String
    public var rules: [PermissionRule]
    /// Exactly what arrived, for echoing back untouched.
    public var raw: JSONValue

    public init(
        type: String,
        behavior: String = "",
        destination: String = "",
        rules: [PermissionRule] = [],
        raw: JSONValue = .object([:])
    ) {
        self.type = type
        self.behavior = behavior
        self.destination = destination
        self.rules = rules
        self.raw = raw
    }

    /// The one shape Bloom offers as a button: rules that would let this call through.
    public var isAllowRules: Bool { type == "addRules" && behavior == "allow" && !rules.isEmpty }

    public static func decode(_ json: JSONValue) -> PermissionSuggestion? {
        guard let type = json["type"]?.stringValue else { return nil }
        return PermissionSuggestion(
            type: type,
            behavior: json["behavior"]?.stringValue ?? "",
            destination: json["destination"]?.stringValue ?? "",
            rules: (json["rules"]?.arrayValue ?? []).compactMap(PermissionRule.decode),
            raw: json
        )
    }

    /// The same suggestion aimed somewhere else.
    ///
    /// Only the destination is rewritten, and only to a value out of the CLI's own enum. The rules
    /// are untouched, so this can move a grant from one lifetime to another and can never change
    /// what is being granted.
    public func aimed(at destination: PermissionDestination) -> PermissionSuggestion {
        var copy = self
        copy.destination = destination.rawValue
        if case .object(var object) = raw {
            object["destination"] = .string(destination.rawValue)
            copy.raw = .object(object)
        }
        return copy
    }
}

/// Where the CLI would put a rule it was handed. Bloom only ever uses `session`; the rest are here
/// because they are what can arrive on a suggestion, and a value Bloom did not expect must survive
/// a round trip rather than be rewritten to something it understands.
///
/// `localSettings` is deliberately never sent. It writes `.claude/settings.local.json` **in the
/// working directory**, which for Bloom is a git worktree: gitignored, not shared with the
/// repository, and deleted when the workspace is archived. A rule granted "for this project
/// forever" would evaporate at exactly the moment it was supposed to matter, and Bloom would have
/// caused a file write it never told anybody about. Project scope lives in Bloom's own database
/// instead, keyed by repository, and is replayed by `PermissionGrantIndex`.
public enum PermissionDestination: String, Sendable, Hashable, CaseIterable, Codable {
    case userSettings
    case projectSettings
    case localSettings
    case session
    case cliArg
}

// MARK: - PermissionAsk

/// A `can_use_tool` control request: the agent asking to run something, with the turn held open
/// until it is answered.
///
/// This only exists because Bloom launches the CLI with `--permission-prompt-tool stdio`. Without
/// that flag the CLI answers on the user's behalf and the answer is no, which is what every
/// `permission-rule` refusal in a transcript is. With it, the CLI stops deciding, writes this on
/// stdout, and blocks. There is no timer on the other end: it waits until answered, until the tool
/// call is aborted, or until stdin closes. Every part of the waiting policy is Bloom's.
public struct PermissionAsk: Sendable, Hashable, Identifiable {
    /// The envelope's `request_id`. The answer must carry it back or it answers nothing.
    public var requestID: String
    public var toolName: String
    /// What the CLI would like the tool called in a UI, when it differs from `toolName`.
    public var displayName: String
    /// The `tool_use` this is about, which is how an ask is tied to the row above it.
    public var toolUseID: String
    /// The tool's arguments. Echoed back on an allow, and the CLI accepts an edited copy.
    public var input: JSONValue
    /// The CLI's one line summary of the call, when it sent one.
    public var summary: String
    /// Why it escalated, in the CLI's words.
    public var reason: String
    /// The structured form of the same, out of a closed set: rule, mode, subcommandResults,
    /// permissionPromptTool, hook, asyncAgent, sandboxOverride, workingDir, safetyCheck,
    /// classifier, other.
    public var reasonType: String
    /// The path that triggered it, when the reason was a path.
    public var blockedPath: String?
    public var suggestions: [PermissionSuggestion]
    /// The CLI asking Bloom not to offer a persistent "do not ask again" button for this one,
    /// because accepting it would write a rule broader than the ask itself.
    ///
    /// Undocumented, and read out of the 2.1.238 binary's own schema, where the field is described
    /// as: "True when the dialog must not offer the persistent 'don't ask again' row for this ask:
    /// accepting it would write a whole-tool allow rule broader than the ask's own verb. Hosts
    /// rendering approve options should omit any persistent-rule affordance when set."
    public var suppressesAlwaysAllow: Bool
    /// The CLI saying a one tap answer is not good enough here, because the tool's own card is the
    /// consent surface, or because the disclosure cannot travel over this wire at all.
    ///
    /// Also undocumented, also from the binary: "True when one-tap Approve/Deny must not be
    /// offered ... Either way the user has to open the session to answer."
    public var requiresUserInteraction: Bool
    /// A safety check somewhere in the reason says at least one part needs a person. False is the
    /// alarming value: it means manual approval is required.
    public var classifierApprovable: Bool?
    /// The whole line, so nothing is lost and a pending ask can be rebuilt from the database.
    public var raw: Data

    public var id: String { requestID }

    public init(
        requestID: String,
        toolName: String,
        displayName: String = "",
        toolUseID: String = "",
        input: JSONValue = .object([:]),
        summary: String = "",
        reason: String = "",
        reasonType: String = "",
        blockedPath: String? = nil,
        suggestions: [PermissionSuggestion] = [],
        suppressesAlwaysAllow: Bool = false,
        requiresUserInteraction: Bool = false,
        classifierApprovable: Bool? = nil,
        raw: Data = Data()
    ) {
        self.requestID = requestID
        self.toolName = toolName
        self.displayName = displayName
        self.toolUseID = toolUseID
        self.input = input
        self.summary = summary
        self.reason = reason
        self.reasonType = reasonType
        self.blockedPath = blockedPath
        self.suggestions = suggestions
        self.suppressesAlwaysAllow = suppressesAlwaysAllow
        self.requiresUserInteraction = requiresUserInteraction
        self.classifierApprovable = classifierApprovable
        self.raw = raw
    }

    /// What to call the tool in a row.
    public var label: String { displayName.isEmpty ? toolName : displayName }

    /// The suggestion Bloom would act on, and the only one it ever offers as a button.
    ///
    /// Exactly one, deliberately. An ask carrying two different allow suggestions is not something
    /// the CLI has been seen to send, and if it ever does, guessing which of them the user meant is
    /// how a feature grants something nobody agreed to. Two suggestions means no rule button and
    /// an allow that lasts for this call only.
    public var allowSuggestion: PermissionSuggestion? {
        let allows = suggestions.filter(\.isAllowRules)
        return allows.count == 1 ? allows[0] : nil
    }

    /// The rules that would stop this question coming back, or empty when there is nothing to
    /// offer. The mockup's third row is this being empty: the CLI offered no rule for a path
    /// outside the worktree, so Bloom does not invent one and the button is not drawn.
    public var rules: [PermissionRule] { allowSuggestion?.rules ?? [] }

    /// The rule text a person reads before widening anything, joined when there is more than one.
    public var ruleText: String {
        rules.map(\.displayText).joined(separator: ", ")
    }

    /// Whether a scope wider than this one call can honestly be offered.
    ///
    /// Three separate ways it can be false, and all three are the CLI's own judgement rather than
    /// Bloom's taste: no rule was suggested, the ask asked for the persistent option to be
    /// suppressed, or the ask says a person has to answer on the tool's own surface.
    public var canWiden: Bool {
        !rules.isEmpty && !suppressesAlwaysAllow && !requiresUserInteraction
    }

    /// The one thing worth putting beside the tool name in a collapsed row: the command for a
    /// shell call, the path for a file one, and the CLI's own description otherwise.
    public var subject: String {
        if let command = input["command"]?.stringValue { return command }
        if let path = input["file_path"]?.stringValue { return path }
        if let url = input["url"]?.stringValue { return url }
        if let blockedPath { return blockedPath }
        return summary
    }

    // MARK: Decoding

    /// Read one `can_use_tool` control request. Nil for anything else, including the other control
    /// request subtypes, which Bloom has no business answering.
    ///
    /// `decision_reason` is stripped of terminal escapes on the way in. The CLI's schema says of
    /// that field, in as many words, "May carry ANSI escapes; sanitize before rendering", and it
    /// is the one string here that comes from a tool rather than from the CLI itself.
    public static func decode(_ json: JSONValue, raw: Data) -> PermissionAsk? {
        guard json["type"]?.stringValue == "control_request",
              let requestID = json["request_id"]?.stringValue,
              let request = json["request"],
              request["subtype"]?.stringValue == "can_use_tool",
              let toolName = request["tool_name"]?.stringValue
        else {
            return nil
        }

        return PermissionAsk(
            requestID: requestID,
            toolName: toolName,
            displayName: request["display_name"]?.stringValue ?? "",
            toolUseID: request["tool_use_id"]?.stringValue ?? "",
            input: request["input"] ?? .object([:]),
            summary: AgentExit.stripEscapes(request["description"]?.stringValue ?? ""),
            reason: AgentExit.stripEscapes(request["decision_reason"]?.stringValue ?? ""),
            reasonType: request["decision_reason_type"]?.stringValue ?? "",
            blockedPath: request["blocked_path"]?.stringValue,
            suggestions: (request["permission_suggestions"]?.arrayValue ?? [])
                .compactMap(PermissionSuggestion.decode),
            suppressesAlwaysAllow: request["suppress_always_allow_rule"]?.boolValue ?? false,
            requiresUserInteraction: request["requires_user_interaction"]?.boolValue ?? false,
            classifierApprovable: request["classifier_approvable"]?.boolValue,
            raw: raw
        )
    }

    /// Rebuild an ask from the bytes the database kept. Used when a workspace is reopened while
    /// its agent is still blocked on the question.
    public static func decode(payload: Data) -> PermissionAsk? {
        guard let json = JSONValue.parse(payload) else { return nil }
        return decode(json, raw: payload)
    }
}

// MARK: - PermissionScope

/// How long an allow lasts. The whole feature turns on this being visible before it is pressed.
public enum PermissionScope: String, Sendable, Hashable, CaseIterable, Codable {
    /// This call and nothing else. Nothing is remembered and the same question comes back.
    case once
    /// Every matching call for the rest of this agent process.
    case session
    /// Every matching call in this project, in every workspace, until it is revoked.
    case project

    /// The verb on the button.
    public var buttonLabel: String {
        switch self {
        case .once: "Allow once"
        case .session: "Allow for this session"
        case .project: "Always allow"
        }
    }

    /// What pressing it costs, said before it is pressed. `rule` is the CLI's own rule text.
    public func consequence(rule: String, project: String) -> String {
        switch self {
        case .once:
            "Just this call. Nothing is remembered and the same question can come back."
        case .session:
            "Any \(rule) for the rest of this session. Forgotten when the agent stops."
        case .project:
            "Any \(rule) in \(project), in every workspace, until you revoke it."
        }
    }
}

// MARK: - PermissionDecision

/// What a person, or a stored grant, said about one ask.
public enum PermissionDecision: Sendable, Hashable {
    /// Let it run. `scope` decides what else it lets through.
    case allow(scope: PermissionScope)
    /// Refuse, in the user's own words, and optionally end the turn there.
    case deny(message: String, endsTurn: Bool)

    /// The default deny sentence, for a button with nothing typed behind it. Written to the model
    /// rather than to a person: it is handed straight back as the tool result.
    public static let defaultDenyMessage =
        "Permission was not granted for this call. Do not try it again. "
        + "Carry on with everything else you can do without it, and say at the end what you skipped."

    /// What Bloom says on the way out, when it is closing the session rather than answering.
    ///
    /// A pending ask must be denied in words rather than left to die against a closed pipe. The
    /// CLI holds the turn open until it gets an answer, an abort, or an EOF, and only the first of
    /// those ends the turn the way turns end: with a result line and a footer. Letting the pipe
    /// close instead produces the crash row this codebase spent three commits making honest.
    public static let quittingMessage =
        "Bloom is closing this session, so this could not be answered. Stop here."

    public static let stoppedMessage =
        "The turn was stopped before this could be answered."

    public var isAllow: Bool {
        if case .allow = self { return true }
        return false
    }

    /// The word a decided row prints.
    public var label: String {
        switch self {
        case .allow(.once): "allowed once"
        case .allow(.session): "allowed for the session"
        case .allow(.project): "always allowed"
        case .deny: "denied"
        }
    }

    /// How this decision is filed in the database. A string rather than an integer so a row read
    /// by a future version says what it means.
    public var storedName: String {
        switch self {
        case .allow(let scope): "allow-\(scope.rawValue)"
        case .deny(_, let endsTurn): endsTurn ? "deny-stop" : "deny"
        }
    }
}

// MARK: - PermissionAnswer

/// The `control_response` line that unblocks the CLI.
///
/// Built as text rather than as a Codable tree because `updatedInput` and the suggestions are
/// arbitrary JSON that came from the CLI in the first place, and the one job here is to hand them
/// back unchanged.
public enum PermissionAnswer {
    /// Encode one answer to one ask. The `request_id` has to match or the CLI ignores it: it
    /// refuses a response whose `toolName` disagrees with the pending ask, and logs the mismatch.
    public static func encode(ask: PermissionAsk, decision: PermissionDecision) throws -> String {
        var response: [String: JSONValue] = [:]

        switch decision {
        case .allow(let scope):
            response["behavior"] = .string("allow")
            // Unedited. Bloom offers no way to change a command before allowing it, and sending
            // anything other than what was asked about would be answering a different question.
            response["updatedInput"] = ask.input
            // `once` sends no permissions at all, which is what makes it mean once. Both wider
            // scopes send the CLI's own suggestion aimed at the session, and nothing else: see
            // `PermissionDestination` for why `localSettings` is never sent, and
            // `PermissionGrantIndex` for where project scope actually lives.
            if scope != .once, let suggestion = ask.allowSuggestion {
                response["updatedPermissions"] = .array([suggestion.aimed(at: .session).raw])
            }
            // What the decision was, for the CLI's own telemetry. Its enum, not Bloom's.
            response["decision"] = .string(scope == .once ? "user_temporary" : "user_permanent")

        case .deny(let message, let endsTurn):
            response["behavior"] = .string("deny")
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            response["message"] = .string(text.isEmpty ? PermissionDecision.defaultDenyMessage : text)
            response["interrupt"] = .bool(endsTurn)
            response["decision"] = .string("user_reject")
        }

        let envelope = JSONValue.object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(ask.requestID),
                "response": .object(response),
            ]),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
    }
}
