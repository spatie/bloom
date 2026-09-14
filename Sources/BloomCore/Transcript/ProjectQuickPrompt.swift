import Foundation

/// A quick prompt the repository offers, stated under `[[quick_prompts]]` in its settings file.
///
/// **Not a `QuickPrompt`, and the difference is who wrote it.** A `QuickPrompt` is a row the owner
/// typed into this app. This is text that arrived by `git pull`, written by whoever last edited the
/// file, and read by an agent with the run of a real worktree the moment it is sent. So there are
/// two things it cannot do that the owner's own prompts can:
///
/// - **It never sends on its own.** `send_immediately` is read and refused, with an issue saying
///   so. Words somebody else wrote go into the composer and wait there to be read, and the owner
///   presses Send. The delivery below can only ever compose.
/// - **It is not edited here.** It is a line in a committed file, and the file is where it
///   changes. What the panel offers instead is a copy into the owner's own library
///   (`personalFields`), which is then theirs to change and to let send.
public struct ProjectQuickPrompt: Identifiable, Sendable, Hashable {
    /// Already trimmed, and never empty: the loader skips an entry without one.
    public var name: String
    /// The words that go into the draft.
    public var text: String
    /// Resolved on the way in, so it is always a symbol `QuickPromptMark` can draw or one emoji.
    public var symbol: String
    /// Whether choosing it opens a new chat for the words rather than using the one on screen.
    public var opensNewChat: Bool
    /// The settings file that stated it, absolute.
    public var source: String

    public init(
        name: String, text: String, symbol: String = QuickPrompt.defaultSymbol,
        opensNewChat: Bool = false, source: String = ""
    ) {
        self.name = name
        self.text = text
        self.symbol = symbol
        self.opensNewChat = opensNewChat
        self.source = source
    }

    /// Derived from the name rather than stored, so a highlighted row is still highlighted after
    /// the file is read again: a reload builds every value afresh and a random id would change
    /// under the panel on every pull. The loader refuses two prompts with the same name in one
    /// list, compared exactly this way, so it is unique.
    public var id: String { Self.identity(of: name) }

    public static func identity(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The second line of a row, by the same rule as the owner's own prompts.
    public var preview: String {
        QuickPrompt(name: name, text: text).preview
    }

    /// What a chat opened for it is called. Always the name, which a project prompt always has.
    public var chatTitle: String { name }

    /// What choosing it does on a surface that may not be able to open a chat. Never a send: see
    /// the head of this type.
    public func delivery(canOpenNewChat: Bool) -> QuickPromptDelivery {
        opensNewChat && canOpenNewChat ? .composeInNewChat : .compose
    }

    /// A new prompt for the owner's own library with these words in it, for Copy to My Quick
    /// Prompts. It does not send, because this one did not: turning that on is a decision the
    /// owner takes on their copy, in the form, after they have read it.
    public var personalFields: QuickPrompt.Fields {
        QuickPrompt.Fields(
            name: name, symbol: symbol, text: text, sendsImmediately: false,
            opensNewChat: opensNewChat
        )
    }
}
