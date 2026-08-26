import Foundation

/// What choosing a quick prompt does: where its words land, and whether they go on their own.
///
/// **Insert and stop is still what a quick prompt does.** Both switches are off on every prompt
/// that exists, off on every prompt written from now on unless somebody turns them on, and off on
/// every row the store reads back that predates the columns. Everything below is what somebody can
/// opt one prompt into, one prompt at a time.
///
/// **Four cases rather than two booleans, because the pair is one decision.** A view asking
/// "should I send?" and then "should I open a chat?" is two questions with three answers between
/// them, and the interesting one is the combination: opening a chat and NOT sending is a tab with
/// words waiting in its composer, which is a coherent thing to want and reads nothing like the
/// other three. So the pair is collapsed here, once, and every surface switches over the four.
///
/// **Neither switch disables the other in the form.** All four combinations do something a person
/// might have meant, so there is nothing to grey out; what the form draws instead is `sentence`,
/// which says in words what the combination will do. A disabled control with no reason attached is
/// worse than a sentence, and hiding one would hide a real behaviour.
///
/// **A surface that cannot do what a prompt asks composes instead.** The create sheet has no chat
/// to send into and no strip to open a tab on, and a conversation dropped in without a workspace
/// model behind it has no way to make a second one. Falling back to the draft is the only answer
/// that loses nothing: the words are in the box, and the person presses Send.
public enum QuickPromptDelivery: Equatable, Sendable, CaseIterable {
    /// The words go into the draft at the caret. Nothing is sent. What every prompt does today.
    case compose
    /// The words go into the draft and the draft is sent, by the same path the Send button takes.
    case send
    /// A new chat opens with the words waiting in its composer.
    case composeInNewChat
    /// A new chat opens and the words are sent in it.
    case sendInNewChat

    /// The pair as the form holds it, before any surface has said what it can do.
    public init(sendsImmediately: Bool, opensNewChat: Bool) {
        switch (sendsImmediately, opensNewChat) {
        case (false, false): self = .compose
        case (true, false): self = .send
        case (false, true): self = .composeInNewChat
        case (true, true): self = .sendInNewChat
        }
    }

    public init(_ prompt: QuickPrompt) {
        self.init(
            sendsImmediately: prompt.sendsImmediately, opensNewChat: prompt.opensNewChat
        )
    }

    /// What this prompt does on a surface that can do only some of it.
    ///
    /// - Parameters:
    ///   - canSend: whether there is a conversation here to send into.
    ///   - canOpenNewChat: whether a second chat can be opened beside this one.
    public static func decided(
        for prompt: QuickPrompt, canSend: Bool, canOpenNewChat: Bool
    ) -> QuickPromptDelivery {
        switch QuickPromptDelivery(prompt) {
        case .compose:
            return .compose
        case .send:
            return canSend ? .send : .compose
        case .composeInNewChat:
            return canOpenNewChat ? .composeInNewChat : .compose
        case .sendInNewChat:
            // Not sent here instead. The whole of that switch is that this conversation is not
            // where the words belong, so when there is no chat to open the send falls away with
            // it and the words wait in the box.
            guard canOpenNewChat else { return .compose }
            return canSend ? .sendInNewChat : .composeInNewChat
        }
    }

    /// Whether the words go without being read again.
    public var sends: Bool { self == .send || self == .sendInNewChat }

    /// Whether a chat is opened for them.
    public var opensNewChat: Bool { self == .composeInNewChat || self == .sendInNewChat }

    /// What the form says under the two switches, in the words of what will happen.
    ///
    /// Written here rather than in the form because it is the same decision the four cases above
    /// are, said to a person instead of to a `switch`, and because a sentence a suite can read back
    /// is a sentence that stays true when a fifth case is added.
    ///
    /// The middle one names the rest of the draft on purpose. Sending straight away sends what is
    /// already in the box along with the prompt, which is the one thing about these switches
    /// somebody could be surprised by after the fact.
    public var sentence: String {
        switch self {
        case .compose:
            "The words go in the composer here, and nothing is sent until you send it."
        case .send:
            "The words go in the composer here and are sent at once, "
                + "along with anything already typed there."
        case .composeInNewChat:
            "A new chat tab opens with the words waiting in its composer. Nothing is sent."
        case .sendInNewChat:
            "A new chat tab opens and the words are sent in it straight away."
        }
    }
}
