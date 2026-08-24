import Foundation

// MARK: - PermissionGrant

/// A rule the user granted from a prompt, and the record that lets them take it back.
///
/// Keyed by **repository**, not by workspace. A Bloom workspace is a git worktree, so anything
/// stored beside the working directory dies with the workspace: that is what makes the CLI's own
/// `localSettings` destination the wrong home for a grant that was described to the user as
/// lasting. Keeping grants here means a rule granted in one worktree is already in force in the
/// next one cut from the same project, which is the behaviour "always allow" promises.
///
/// Nothing here is a settings file. Bloom writes none, and answers matching asks itself.
public struct PermissionGrant: Identifiable, Sendable, Hashable, Codable {
    public var id: PermissionGrantID
    public var repoID: RepoID
    /// The CLI's tool name, exactly as it arrived.
    public var toolName: String
    /// The CLI's `ruleContent`, exactly as it arrived. Nil is a rule covering the whole tool.
    public var ruleContent: String?
    public var grantedAt: Date
    /// The last time this grant answered an ask, so the list can say whether it is earning its
    /// place or was a one-off somebody has forgotten about.
    public var lastUsedAt: Date?
    /// How many asks it has answered. The list shows it for the same reason.
    public var useCount: Int
    /// What the ask looked like when it was granted, in one line, so the list can say what the
    /// user was actually looking at when they pressed the button. A rule on its own is often not
    /// enough to remember a decision by.
    public var grantedFor: String

    public init(
        id: PermissionGrantID = .new(),
        repoID: RepoID,
        toolName: String,
        ruleContent: String? = nil,
        grantedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        grantedFor: String = ""
    ) {
        self.id = id
        self.repoID = repoID
        self.toolName = toolName
        self.ruleContent = ruleContent
        self.grantedAt = grantedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.grantedFor = grantedFor
    }

    public var rule: PermissionRule {
        PermissionRule(toolName: toolName, ruleContent: ruleContent)
    }

    /// The CLI's own spelling, which is what the revocation list shows. Showing anything else
    /// would mean a person revoking a rule they never read.
    public var displayText: String { rule.displayText }

    public static func granting(_ rule: PermissionRule, repoID: RepoID, for subject: String = "") -> PermissionGrant {
        PermissionGrant(
            repoID: repoID,
            toolName: rule.toolName,
            ruleContent: rule.ruleContent,
            grantedFor: subject
        )
    }

    /// Every grant one decision would write, or none when the decision was not a project one.
    ///
    /// Here rather than in each runner because it is Bloom's own bookkeeping rather than either
    /// backend's protocol. `SessionRunner`'s head argues that runner surface is not shared, and it
    /// is right about the protocol; this is not protocol. It was two identical loops under two
    /// identical comments, which meant a change to what project scope stores had to be made twice
    /// and could be made once.
    public static func all(
        granting decision: PermissionDecision, from ask: PermissionAsk, repoID: RepoID
    ) -> [PermissionGrant] {
        guard case .allow(.project) = decision else { return [] }

        return ask.rules.map { granting($0, repoID: repoID, for: ask.subject) }
    }
}

// MARK: - PermissionGrantIndex

/// Deciding whether a stored grant already answers an ask.
///
/// The matching rule is **exact equality, and only exact equality**, on the tool name and on the
/// CLI's own `ruleContent`. No prefix matching, no globbing, no case folding, no trimming of
/// whitespace, no resolving of paths. If any of those were done here, Bloom would be deciding
/// that two rules mean the same thing, and Bloom is not the component that knows that: a rule is
/// a string in a syntax the CLI owns and evolves.
///
/// The consequence is deliberate and worth stating. Bloom under-matches rather than over-matches.
/// A rule Bloom cannot recognise means one more question, which costs a click. The opposite
/// mistake means a command running because Bloom decided it resembled something the user once
/// approved, and there is no click that takes that back.
///
/// A wildcard grant still works exactly as well as the CLI's own would, because the wildcard is in
/// the string the CLI composed: when the CLI decides the right rule for `bin/test --filter X` is
/// `bin/test:*`, it proposes that same string for `bin/test --filter Y`, and the two match here
/// without Bloom knowing what `*` means.
public enum PermissionGrantIndex {
    /// The grants that between them cover every rule this ask would need, or nil when the ask
    /// still has to be put to a person.
    ///
    /// Every rule in the suggestion has to be covered, not merely one of them. A suggestion
    /// carrying two rules is one decision about two things, and honouring half of it would be
    /// allowing something on the strength of a grant that was about something else.
    public static func match(ask: PermissionAsk, grants: [PermissionGrant]) -> [PermissionGrant]? {
        // The same three gates the buttons use. An ask the user was never allowed to widen must
        // not be answered from a stored grant either, or the flag the CLI set would mean nothing
        // the second time the question came round.
        guard ask.canWiden, let suggestion = ask.allowSuggestion else { return nil }

        var matched: [PermissionGrant] = []
        for rule in suggestion.rules {
            guard let grant = grants.first(where: { $0.rule == rule }) else { return nil }
            matched.append(grant)
        }
        return matched.isEmpty ? nil : matched
    }

    /// The sentence the transcript prints when Bloom answered instead of the user.
    ///
    /// A call that ran because of a decision made days ago must not look like a call that simply
    /// ran. This is the whole of that: the rule, in the CLI's spelling, and where it came from.
    public static func note(for grants: [PermissionGrant]) -> String {
        let rules = grants.map(\.displayText).joined(separator: ", ")
        return "Allowed by \(rules), which you approved for this project."
    }
}

// MARK: - PendingPermissionAsk

/// A question a session is still holding a turn open for, as it comes back out of the database.
///
/// Durable because the alternative is a trap. An agent blocked on a question keeps its turn open
/// for as long as it takes, and there is no timer on the other end, so a Bloom that forgot the
/// question on quit would come back to a live process it could no longer answer and a transcript
/// that simply stopped mid sentence.
public struct PendingPermissionAsk: Identifiable, Sendable, Hashable {
    public var requestID: String
    public var sessionID: SessionID
    public var ask: PermissionAsk
    public var askedAt: Date

    public var id: String { requestID }

    public init(requestID: String, sessionID: SessionID, ask: PermissionAsk, askedAt: Date) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.ask = ask
        self.askedAt = askedAt
    }
}

// MARK: - How a resolved ask was resolved

/// The words written into `permission_asks.decision`, and what a decided row should say.
///
/// Kept as strings rather than as a Swift enum on the column, because a database written by a
/// later Bloom has to be readable by this one: an unrecognised word means "decided, somehow",
/// which is still enough to stop drawing live buttons.
public enum PermissionAskOutcome {
    /// Written when the app is closing a session down rather than answering it.
    public static let quit = "quit"
    /// Written when the turn was stopped underneath the question.
    public static let stopped = "stopped"
    /// Written at launch over anything left open by a process that is no longer running.
    public static let abandoned = "abandoned"
    /// Written when a stored project grant answered it without troubling anybody.
    public static let auto = "allow-project-auto"

    /// Whether this outcome means nobody ever actually answered.
    public static func wentUnanswered(_ decision: String) -> Bool {
        [quit, stopped, abandoned].contains(decision)
    }

    /// What a row says about an ask that was never answered. No buttons, and no suggestion that
    /// pressing something would help: the process it belonged to is gone.
    public static func summary(_ decision: String) -> String {
        switch decision {
        case quit: "Bloom closed this session before the question was answered."
        case stopped: "The turn was stopped before this was answered."
        case abandoned: "Bloom was not running when this was asked, so it went unanswered."
        default: ""
        }
    }

    /// The one useful thing to say next, in `SetupDiagnosis`'s sense: real advice or nothing.
    public static func advice(_ decision: String) -> String {
        wentUnanswered(decision)
            ? "Nothing was lost. The worktree still holds whatever the agent had changed, and the turn can be sent again."
            : ""
    }
}

// MARK: - PermissionResolution

/// One question, answered.
///
/// Carries the sentence a row should print as well as the decision, because the interesting case
/// is the one where nobody was asked: a call allowed by a rule granted days ago must say so, or a
/// person cannot tell it from a call that simply ran, and cannot judge whether to take the rule
/// back. `note` is empty when a person answered, which is the case that needs no explanation.
public struct PermissionResolution: Sendable, Hashable {
    public var requestID: String
    public var toolUseID: String
    /// The stored spelling, out of `PermissionDecision.storedName` or `PermissionAskOutcome`.
    public var decision: String
    /// What the transcript should say about how this was decided, or empty.
    public var note: String

    public init(requestID: String, toolUseID: String = "", decision: String, note: String = "") {
        self.requestID = requestID
        self.toolUseID = toolUseID
        self.decision = decision
        self.note = note
    }
}
