import Foundation

/// The words asked before a quick prompt is thrown away.
///
/// **They are here rather than beside the button because a quick prompt is something the owner
/// wrote and there is no undo for it.** Delete used to remove the row on the click, from the form
/// and from the row's own context menu, so a stray press on a list opened to pick from cost a
/// paragraph nobody had a copy of. `ProjectRemoval` is the shape this follows: the sentences live
/// in the core where a test can read them, and only the dialog they are worn in is the app's.
///
/// One question for both routes, for the reason `ProjectRemoval` gives about its three: two
/// wordings of the same question drift, and the only thing that notices is the person being asked.
public enum QuickPromptDeletion {
    /// The one line a reader reliably reads, naming the prompt so the answer is about the right one.
    ///
    /// The name is cut rather than left whole. A quick prompt with no name of its own is listed by
    /// its first line, which runs to `QuickPrompt.previewLength`, and a title that long turns a
    /// 260 point dialog into six lines of question with the buttons pushed off the bottom.
    public static func title(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Delete this quick prompt?" }
        guard trimmed.count > nameLength else { return "Delete \u{201C}\(trimmed)\u{201D}?" }
        let cut = trimmed.prefix(nameLength).trimmingCharacters(in: .whitespaces)
        return "Delete \u{201C}\(cut)\u{2026}\u{201D}?"
    }

    /// About as much of a name as fits on one line of the dialog above.
    static let nameLength = 40

    /// What the answer does, as consequences rather than as "are you sure?".
    public static let message =
        "The prompt goes from every workspace. Nothing already sent is affected, and it cannot be "
        + "brought back."

    public static let confirmLabel = "Delete Prompt"
    public static let cancelLabel = "Cancel"
}
