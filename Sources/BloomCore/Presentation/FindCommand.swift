import Foundation

/// What Cmd+F does, which on this platform is always "find in the thing I am looking at".
///
/// **What Bloom did.** Cmd+F navigated the sidebar to a separate Search screen, replacing the whole
/// centre column: the most reflexive keystroke there is took the reader away from what they were
/// reading. There was no Cmd+G anywhere in the app, and the terminal shipped a working find bar
/// that nothing ever asked for. Mail, Safari, Terminal, Preview, Notes and Xcode all open a find
/// interface over the content in front and step it with Cmd+G, without exception.
///
/// **The rule, and why Search is still on the end of it.** The pane in front gets first refusal:
/// a shell and a source editor both have a real find bar and answer for themselves. Where nothing
/// in front can find, the workspace search is what Cmd+F has always opened, and it reads the full
/// text of every transcript, so falling through to it means the key keeps everything it could do
/// before and gains what it should have done all along. It is also on Shift+Cmd+F of its own, so
/// somebody who wants it from inside a terminal has a key that always means it.
///
/// **The one thing that changed when the Search screen went.** The fall through lands in the
/// window's own search rather than on a sidebar destination. Nothing about either key has moved
/// since: this enum has always said "the pane in front, or the workspace search", and the
/// workspace search has been a screen, then a field in the toolbar, and is a panel over the window
/// now. Which of those it is is the app target's business; the rule is the same one either way.
public enum FindCommand {
    public enum Target: Equatable, Sendable {
        /// The pane in front answers, through its own find bar.
        case findInPlace
        /// The window's search, which reaches names, branches, projects and the full text of every
        /// transcript on the machine. See `SearchPanelResults`.
        case workspaceSearch
    }

    /// Cmd+F.
    ///
    /// - Parameters:
    ///   - canFindInPlace: whether anything in the responder chain has a find interface.
    ///   - hasProjects: whether there is anything to search. Keyed on projects rather than on live
    ///     workspaces, because search finds archived ones too.
    public static func find(canFindInPlace: Bool, hasProjects: Bool) -> Target? {
        if canFindInPlace { return .findInPlace }
        return hasProjects ? .workspaceSearch : nil
    }

    /// Cmd+G and Shift+Cmd+G, which only ever mean the find already running in front of you.
    ///
    /// Stepping the matches has no meaning in the workspace search: that is a list of results with
    /// its own keyboard, and moving the highlight down it would not be finding a next anything.
    public static func step(canFindInPlace: Bool) -> Target? {
        canFindInPlace ? .findInPlace : nil
    }
}
