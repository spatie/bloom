import Foundation

/// What a row of the quick prompt panel draws and what choosing it does, asked once of either kind
/// of prompt so the panel and the composer switch over one value rather than two.
///
/// The composer's pick path used to take a `QuickPrompt`, and the tempting way to put a project's
/// prompt through it was to build one: same name, same words, `sendsImmediately` false. That works
/// until somebody edits the conversion, and the rule that a project prompt never sends would then
/// live in a line of glue in a view. Here the row keeps its kind to the end, and a project row's
/// delivery is `ProjectQuickPrompt.delivery`, which has no way to answer with a send.
extension QuickPromptPanelRow {
    /// The words that go into the draft.
    public var text: String {
        switch self {
        case .personal(let prompt): prompt.text
        case .project(let prompt): prompt.text
        }
    }

    /// The stored mark, for `QuickPromptMarkView`.
    public var symbol: String {
        switch self {
        case .personal(let prompt): prompt.symbol
        case .project(let prompt): prompt.symbol
        }
    }

    /// The row's second line, or nil when the first line already is the preview. Only an owner's
    /// prompt with no name can be that: a project prompt the loader kept always has one.
    public var secondLine: String? {
        switch self {
        case .personal(let prompt): prompt.hasSeparatePreview ? prompt.preview : nil
        case .project(let prompt): prompt.preview
        }
    }

    /// What a chat opened for it is called, or nil for the strip's own numbered one.
    public var chatTitle: String? {
        switch self {
        case .personal(let prompt): prompt.chatTitle
        case .project(let prompt): prompt.chatTitle
        }
    }

    /// Whether the row can be edited and deleted here. A project's prompt is a line in a committed
    /// file and changes there; what the panel offers in place of the pencil is a copy.
    public var isEditable: Bool {
        if case .personal = self { return true }
        return false
    }

    /// What choosing it does on a surface that can do only some of the four things.
    public func delivery(canSend: Bool, canOpenNewChat: Bool) -> QuickPromptDelivery {
        switch self {
        case .personal(let prompt):
            QuickPromptDelivery.decided(for: prompt, canSend: canSend, canOpenNewChat: canOpenNewChat)
        case .project(let prompt):
            prompt.delivery(canOpenNewChat: canOpenNewChat)
        }
    }

    /// What VoiceOver reads after the name: the words, where they came from, and anything choosing
    /// the row does beyond writing into the box.
    ///
    /// The sentence is the one the prompt states, not the one this surface would reduce it to,
    /// because it is the same value the owner's rows have always read out. "From this project" is
    /// the heading a sighted reader gets and a VoiceOver user arrowing past it does not.
    public var accessibilityValue: String {
        switch self {
        case .personal(let prompt):
            return [prompt.preview, QuickPromptDelivery(prompt).sentence]
                .compactMap { $0 }
                .joined(separator: ". ")
        case .project(let prompt):
            return [prompt.preview, "From this project", prompt.delivery(canOpenNewChat: true).sentence]
                .compactMap { $0 }
                .joined(separator: ". ")
        }
    }
}
