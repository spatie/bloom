import Foundation

/// What a pane is called when nobody has said otherwise.
///
/// ## Furniture, not a description
///
/// A workspace is named after the work: `WorkspaceNamer` asks a model what the first prompt was
/// about, and the sidebar reads "Describe fade-in animation feel". A pane inside that workspace is
/// not named after anything. It is a chat, a shell or a page, and what the strip has to tell you
/// is which of them it is and which one of several you are in. That is a label, and a label that
/// changes on its own is a label you cannot navigate by.
///
/// **This is the seam between the two mechanisms and it is deliberate.** The first chat of a
/// workspace used to be titled `Git.title(from: prompt)`, so a workspace opened with "are you
/// there" carried a tab reading "Are you there" for as long as that conversation lived, next to a
/// sidebar row the naming call had meanwhile given a real name. Two names for one thing, one of
/// them a fragment of a sentence nobody wrote as a title. The workspace keeps its name from the
/// prompt; the tab is furniture and says `Chat`.
///
/// Rows written before that change keep the names they have. Renaming them would be a migration
/// over the owner's own conversations to make old tabs match new ones, which is a worse trade
/// than a strip that is briefly inconsistent, and the inconsistency ends as those chats are
/// closed.
///
/// ## The numbering
///
/// The lowest free number, so the run reads `Chat`, `Chat 2`, `Chat 3` with no gaps in it.
///
/// The case that decides it: three chats called Chat, Chat 2 and Chat 3, close Chat 2, open a new
/// one. This answers **Chat 2**, filling the gap, rather than Chat 4. Counting what is open and
/// adding one, which is what the terminal tabs did before this, answers Chat 4 and leaves the
/// strip reading Chat, Chat 3, Chat 4: three tabs whose numbers say there is a fourth somewhere
/// off the end. The number is a position in the strip, not a serial, and there is nothing for it
/// to be unique against: two chats have never had to have different names, a person may type the
/// same name over both, and the identity the app navigates by is the row id.
///
/// What that costs is that a name can be reused: close Chat 2, open a new chat, and the archive
/// holds two conversations called Chat 2. It held any number of them called "New session" before
/// this, so nothing that could tell them apart has been lost.
///
/// **Per workspace, and among what is open.** The taken set a caller passes is that workspace's
/// live panes: a chat archived an hour ago holds no number, and the workspace in the next window
/// has its own Chat. A strip is the only place these names are read, and a strip shows one
/// workspace.
public enum PaneNaming {
    /// The name a new conversation gets. See the note above: never the prompt, never the model's
    /// answer, always this.
    public static let chat = "Chat"
    public static let terminal = "Terminal"
    public static let browser = "Browser"

    /// What the strip draws over a conversation whose title is empty, and therefore the name
    /// `workspace_tabs` reports and `workspace_tab_select` takes back for it. Not `chat` above:
    /// that is the name a new pane is given, and a chat somebody emptied the title of is not one.
    public static let untitledChat = "Untitled"

    /// The name for a strip entry pointing at a tool tab that has gone. Only the Go to Tab menu
    /// prints it, because it draws a row per entry; `workspace_tabs` drops such an entry rather
    /// than reporting a tab that is not there.
    public static let missingTab = "Tab"

    /// The bare name if it is free, otherwise the base and the lowest free number from 2 up.
    ///
    /// `taken` is every name currently in the strip for that kind, including ones a person typed:
    /// somebody who has renamed a chat to "Chat 2" themselves has taken that name, and handing it
    /// out again would put two identical tabs side by side, which is the one thing numbering is
    /// there to prevent.
    public static func nextTitle(base: String, taken: some Sequence<String>) -> String {
        let taken = Set(taken)
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Whether a title is one of these rather than one a person typed.
    ///
    /// Used where a pane nobody named is worth less than one somebody did: the launch sweep that
    /// decides which of the bottom panel's old terminal tabs are worth carrying into the centre
    /// column asks exactly this.
    public static func isDefaultTitle(_ title: String, base: String) -> Bool {
        if title == base { return true }
        guard title.hasPrefix(base + " ") else { return false }
        return Int(title.dropFirst(base.count + 1)) != nil
    }
}
