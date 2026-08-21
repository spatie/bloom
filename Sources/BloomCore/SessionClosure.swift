import Foundation

/// What closing a conversation costs, and therefore whether to ask before doing it.
///
/// One decision, in one place, because there are two doors and they did not agree. The tab's own
/// close button was hidden whenever a workspace was down to its last conversation
/// (`canClose: model.sessions.count > 1`), while "Close Session" in the File menu, which holds
/// Cmd+W for the whole app, has never had such a guard and closes the active conversation whatever
/// else is open. So the last conversation was always closable, by keyboard, and the button only
/// pretended otherwise. The owner reported it as "I cannot close the first tab", which is exactly
/// what it looks like from outside.
///
/// The state the button was guarding is not one to be guarded from. It is designed for, at some
/// length: `CenterPaneView.noConversationState` is written for it word by word ("This workspace has
/// no conversation"), the tab strip reasons about "a workspace whose conversations have all been
/// closed" in two places, and `WorkspaceStartMode.consumeOpensOnTerminal` makes a workspace that
/// has never had a conversation at all, so a workspace can be born in it. There is a way out of it
/// on screen in every case: the empty state offers a terminal, and the plus offers a chat.
///
/// So the button comes back, and this is what stops that being a silent loss. A closed conversation
/// is archived rather than deleted, but nothing in the app clears `archivedAt` on a session and
/// nothing lists archived ones, so from where the user is standing it does not come back. Both
/// doors ask the same question now, which also fixes the sharper half of the old arrangement:
/// Cmd+W destroyed the last transcript in a workspace without a word.
///
/// An option set rather than a case, because the two costs are independent and a conversation that
/// is both mid turn and the only one has to say both things rather than the more alarming one.
public struct SessionClosure: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A turn is in flight. It stops where it is and cannot be picked up again.
    public static let stopsATurn = SessionClosure(rawValue: 1 << 0)

    /// It is the workspace's only conversation, so the workspace is left with none.
    public static let leavesNoConversation = SessionClosure(rawValue: 1 << 1)

    /// - Parameters:
    ///   - isRunning: whether the agent is in the middle of a turn.
    ///   - otherConversations: how many conversations the workspace would still have afterwards.
    public static func closing(isRunning: Bool, otherConversations: Int) -> SessionClosure {
        var cost: SessionClosure = []
        if isRunning { cost.insert(.stopsATurn) }
        if otherConversations <= 0 { cost.insert(.leavesNoConversation) }
        return cost
    }

    /// Whether to ask first.
    ///
    /// Nothing to lose means no dialog, which is the rule this replaces and keeps: "a dialog that
    /// appears when there is nothing to lose is a dialog that stops being read". An idle
    /// conversation with others beside it still closes on the first click.
    public var needsConfirmation: Bool { !isEmpty }

    /// The question, named rather than "Are you sure?", so it can be answered without opening the
    /// window behind it to find out which conversation it is about.
    ///
    /// "Conversation" rather than "session", following the words the empty state already uses at
    /// the user: `noConversationState` says "This workspace has no conversation."
    public func title(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmed.isEmpty ? "This conversation" : trimmed

        if contains(.stopsATurn) { return "\(subject) is still working" }
        if contains(.leavesNoConversation) { return "\(subject) is the only conversation here" }
        return "Close \(subject)?"
    }

    /// What is lost, one sentence per consequence, the sharper one first.
    ///
    /// A list rather than a paragraph, because a conversation can carry both costs and the caller
    /// joins them with a blank line between. Empty for a closure with nothing to say, which is one
    /// nobody asks about.
    public var reasons: [String] {
        var lines: [String] = []
        if contains(.stopsATurn) {
            lines.append(
                """
                Closing it stops the agent. The turn it is in the middle of will not be finished, \
                and it cannot be resumed.
                """
            )
        }
        if contains(.leavesNoConversation) {
            lines.append(
                """
                It is the only conversation in this workspace, and a closed conversation does not \
                come back. The worktree and anything else open here are untouched, and a new \
                conversation can be started from the plus above the pane.
                """
            )
        }
        return lines
    }

    /// The destructive button. It answers the title, so it changes with it.
    public var confirmTitle: String {
        contains(.stopsATurn) ? "Close anyway" : "Close it"
    }

    /// The way out. No cancel button in this app carries the default action, so this is what
    /// Escape does and it should read as the safe answer rather than as a shrug.
    public var cancelTitle: String {
        contains(.stopsATurn) ? "Keep working" : "Keep it"
    }
}
