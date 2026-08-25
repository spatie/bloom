import Testing
@testable import BloomCore

/// Cmd+W closing something other than what is in front.
///
/// It was Close Session, gated on the workspace having a conversation rather than on which tab was
/// selected, so pressing it over a browser, a review or the notes closed a chat in another pane.
@Suite("What Cmd+W closes")
struct TabClosureTests {
    private let chat = PaneContent.chat(SessionID("session-1"))
    private let terminal = PaneContent.tool("tool-1")

    @Test("a tab nobody has split closes itself")
    func unsplitTab() {
        #expect(TabClosure.target(selectedTab: terminal, focusedPaneContent: terminal) == terminal)
    }

    /// The bug, stated: a browser tab in front does not close a conversation.
    @Test("the tab in front is what closes, not the workspace's conversation")
    func theTabInFront() {
        #expect(TabClosure.target(selectedTab: terminal, focusedPaneContent: nil) == terminal)
        #expect(TabClosure.target(selectedTab: terminal, focusedPaneContent: terminal) != chat)
    }

    /// A tab's panes each hold a whole conversation or a whole shell, so the one with the keyboard
    /// is what closing means. Cmd+Ctrl+W is the item that takes a pane out of the arrangement.
    @Test("a split tab closes the pane the keyboard is in")
    func splitTab() {
        #expect(TabClosure.target(selectedTab: chat, focusedPaneContent: terminal) == terminal)
        #expect(TabClosure.target(selectedTab: chat, focusedPaneContent: chat) == chat)
    }

    @Test("a workspace with no tabs has nothing to close")
    func nothingOpen() {
        #expect(TabClosure.target(selectedTab: nil, focusedPaneContent: nil) == nil)
        #expect(TabClosure.target(selectedTab: nil, focusedPaneContent: chat) == nil)
    }
}
