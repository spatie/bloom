import Foundation

/// Why a tool call produced nothing, when the reason was not the tool.
///
/// A denied call is not a failed one. Nothing broke: the session's permission mode declined the
/// call, or a person did, and the agent was handed a sentence saying so instead of output. The
/// protocol marks both with `is_error`, which is how a denial ended up drawn in the same alarming
/// red as a command that crashed, with the sentence thrown away.
///
/// The distinction is read off the payload rather than guessed from the text. A `user` event
/// carries a `tool_result_meta` array beside the message, one entry per call, and an entry gets a
/// `non_execution_kind` only when the call did not run. A tool that ran and failed has no entry.
/// Measured over a real session: six denials all carried `user-rejected`, and the two genuine
/// failures beside them (a failing test suite, a shell exiting 1) carried nothing.
public enum ToolRefusal: Sendable, Hashable {
    /// Every value the CLI can stamp on the field, in the CLI's own order. Kept here so the test
    /// suite can assert that the whole set is accounted for rather than only the ones somebody
    /// happened to think of.
    public static let protocolKinds = [
        "user-rejected",
        "permission-rule",
        "automode-blocked",
        "automode-unavailable",
        "automode-parsing-error",
        "interrupted",
        "cancelled",
    ]

    /// Permission was not given. The permission mode declined it, or a person said no.
    case denied
    /// The call was still in flight when the turn was stopped.
    case stopped
    /// The CLI says the call did not run, and the reason was nobody's decision: auto mode could
    /// not reach a verdict, or the reason is a spelling this version does not know about.
    case notRun

    /// The word a collapsed row prints where a failure prints "error".
    public var label: String {
        switch self {
        case .denied: "denied"
        case .stopped: "stopped"
        case .notRun: "not run"
        }
    }

    /// What the row means, for a tooltip and for VoiceOver, when the CLI's own sentence is not
    /// being shown.
    public var summary: String {
        switch self {
        case .denied: "The agent asked to run this and permission was not granted."
        case .stopped: "The turn was stopped before this call ran."
        case .notRun: "This call did not run."
        }
    }

    /// The one thing that would let it through next time, or nil when there is nothing to suggest.
    public var remedy: String? {
        switch self {
        case .denied: "Pick a permission mode under the composer that allows it, then ask again."
        case .stopped, .notRun: nil
        }
    }

    /// The protocol's own spelling, as it appears in `tool_result_meta[].non_execution_kind`.
    ///
    /// The field is a closed set of seven, read out of the 2.1.238 binary rather than out of
    /// documentation:
    ///
    ///     ["user-rejected", "permission-rule", "automode-blocked",
    ///      "automode-unavailable", "automode-parsing-error", "interrupted", "cancelled"]
    ///
    /// `permission-denied` was matched here and is not one of them, so it never fired. What did
    /// fire, and fell through to `.notRun` with no remedy, was `permission-rule`: the CLI stamps
    /// that on every refusal a permission rule or a permission mode produced, which is the exact
    /// case the remedy was written for. The mapping is now the CLI's own, taken from the function
    /// that stamps the field:
    ///
    /// - `user-rejected` when the decision came back `ask` and nobody was there to answer, or a
    ///   person answered no.
    /// - `permission-rule` when a rule or a mode settled it.
    /// - `automode-blocked` when auto mode's classifier declined.
    ///
    /// Those three are decisions, and a decision is `.denied`. The CLI itself separates the other
    /// four out as transient: `automode-unavailable` and `automode-parsing-error` mean the
    /// classifier could not answer at all rather than that it said no, and `interrupted` and
    /// `cancelled` mean the turn ended underneath the call. So the first two are `.notRun` and the
    /// last two are `.stopped`.
    ///
    /// An unrecognised kind still means the call did not run, because that is what the field is
    /// for, so it becomes `.notRun` rather than being read as a failure. An empty or missing kind
    /// is not a refusal at all and returns nil, which leaves the existing error rendering alone.
    public init?(protocolKind: String?) {
        switch protocolKind {
        case "user-rejected", "permission-rule", "automode-blocked": self = .denied
        case "interrupted", "cancelled", "canceled": self = .stopped
        case "automode-unavailable", "automode-parsing-error": self = .notRun
        case .some(let kind) where !kind.isEmpty: self = .notRun
        default: return nil
        }
    }
}

/// What a stored `tool_result` payload amounts to, without decoding the whole event.
///
/// A tool result is the largest payload in a session and the transcript folds every one of them
/// onto its call as it loads, so this reads the three things a collapsed row needs and stops. The
/// reason is only lifted out for a refusal, whose text is one sentence; a real result runs to
/// megabytes and never belongs in a row header.
public struct ToolResultSummary: Sendable, Hashable {
    public var isError: Bool
    public var refusal: ToolRefusal?
    /// The sentence the CLI gave for a refusal. Empty for anything else.
    public var reason: String

    public init(isError: Bool = false, refusal: ToolRefusal? = nil, reason: String = "") {
        self.isError = isError
        self.refusal = refusal
        self.reason = reason
    }

    public static func decode(_ payload: Data) -> ToolResultSummary {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else {
            return ToolResultSummary()
        }

        let results = content.filter { (($0["type"] as? String) ?? "tool_result") == "tool_result" }
        guard results.contains(where: { ($0["is_error"] as? Bool) == true }) else {
            return ToolResultSummary()
        }

        let meta = object["tool_result_meta"] as? [[String: Any]] ?? []
        // Matched by id rather than by position, because one `user` event can close several calls
        // and the array beside it is not promised to be in the same order.
        let ids = Set(results.compactMap { $0["tool_use_id"] as? String })
        let kind = meta
            .first { ids.contains(($0["id"] as? String) ?? "") }
            .flatMap { $0["non_execution_kind"] as? String }

        guard let refusal = ToolRefusal(protocolKind: kind) else {
            return ToolResultSummary(isError: true)
        }

        return ToolResultSummary(
            isError: true,
            refusal: refusal,
            reason: firstLine(of: results.first { ($0["is_error"] as? Bool) == true })
        )
    }

    /// A refusal sentence, cut to the one line a row can hold. The content is a bare string in
    /// every refusal seen so far, and the block form is read anyway so a future one still says
    /// something rather than nothing.
    private static func firstLine(of block: [String: Any]?) -> String {
        guard let block else { return "" }
        let text: String
        if let string = block["content"] as? String {
            text = string
        } else if let blocks = block["content"] as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return ""
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
