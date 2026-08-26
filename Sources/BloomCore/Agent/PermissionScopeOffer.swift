import Foundation

/// Which allow buttons a permission card may honestly draw, and the sentence under them.
///
/// This used to be three `if`s inside `PermissionAskRowView`, which was fine while every chat was
/// in a worktree. Ask Bloom is not. `permission_grants.repo_id` is `NOT NULL REFERENCES repos(id)`,
/// so "Always allow" is a rule stored against a project, and a conversation that has no project
/// cannot store one. The button would still have been drawn, would still have been pressed, and
/// would have granted for one call what it promised for ever.
///
/// So the widest honest scope is computed rather than assumed, and the card says which it is. A
/// scope missing from a card with no explanation is the failure this type exists to prevent, which
/// is why `explanation` is not optional: there is always a sentence.
public struct PermissionScopeOffer: Sendable, Hashable {
    /// The allows this ask may offer, widest first. Never empty: allowing one call is always on
    /// the table, and it is the only thing that is.
    public let scopes: [PermissionScope]
    /// What the widest of them would cost, said before it is pressed, or why there is nothing
    /// wider than one call here.
    public let explanation: String

    public init(scopes: [PermissionScope], explanation: String) {
        self.scopes = scopes
        self.explanation = explanation
    }

    /// The one the card fills in and gives the return key to.
    public var prominent: PermissionScope { scopes.first ?? .once }

    /// Whether anything wider than this single call is on offer.
    public var widens: Bool { scopes.count > 1 }

    /// - Parameter project: what the chat's project is called, or nil when it has none. Nil is Ask
    ///   Bloom, and it is the whole reason this takes an optional rather than a name and a flag: a
    ///   card that had to be told separately that the name was not real would be a card that could
    ///   be told wrongly.
    public static func of(ask: PermissionAsk, project: String?) -> PermissionScopeOffer {
        guard ask.canWiden else {
            return PermissionScopeOffer(scopes: [.once], explanation: reasonThereIsNoRule(for: ask))
        }

        guard let project, !project.isEmpty else {
            return PermissionScopeOffer(
                scopes: [.session, .once],
                explanation: PermissionScope.session.consequence(rule: ask.ruleText, project: "")
                    + " There is no project behind this conversation, and a rule that lasts is "
                    + "stored against one, so this session is as far as an allow can reach here."
            )
        }

        return PermissionScopeOffer(
            scopes: [.project, .session, .once],
            explanation: PermissionScope.project.consequence(rule: ask.ruleText, project: project)
        )
    }

    /// Why the only button is Allow once. Two cases, and telling them apart matters: one is the
    /// CLI declining to have a rule written, the other is there being no rule to write.
    private static func reasonThereIsNoRule(for ask: PermissionAsk) -> String {
        guard !ask.rules.isEmpty else {
            return "No rule was offered for this, so it can only be allowed once."
        }
        return "\(ask.ruleText) cannot be granted from here: "
            + "the agent asked for this one to be decided on its own."
    }
}

public extension PermissionScope {
    /// The verb on a button that is not the prominent one, where the card's other buttons already
    /// supply the word "allow" and repeating it three times reads as a form rather than a choice.
    var compactLabel: String {
        switch self {
        case .once: "Once"
        case .session: "This session"
        case .project: "Always allow"
        }
    }
}
