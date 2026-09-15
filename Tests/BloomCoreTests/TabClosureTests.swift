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

    @Test("closing a background tab preserves selection on either side")
    func backgroundSelection() {
        let page = PaneContent.tool("page")
        let tabs = [chat, terminal, page]
        #expect(TabClosure.selectionAfterClosing(chat, selected: terminal, tabs: tabs) == terminal)
        #expect(TabClosure.selectionAfterClosing(page, selected: terminal, tabs: tabs) == terminal)
    }

    @Test("closing the active tab selects its left neighbour across tab kinds")
    func activeSelection() {
        let secondChat = PaneContent.chat(SessionID("session-2"))
        let tabs = [chat, terminal, secondChat]
        #expect(TabClosure.selectionAfterClosing(terminal, selected: terminal, tabs: tabs) == chat)
        #expect(TabClosure.selectionAfterClosing(secondChat, selected: secondChat, tabs: tabs) == terminal)
    }

    @Test("closing the first tab selects the tab to its right")
    func firstTab() {
        #expect(TabClosure.selectionAfterClosing(chat, selected: chat, tabs: [chat, terminal]) == terminal)
    }

    @Test("closing the only tab leaves no selection")
    func lastTab() {
        #expect(TabClosure.selectionAfterClosing(chat, selected: chat, tabs: [chat]) == nil)
    }

    @Test("a repeated close does not move the surviving selection")
    func alreadyClosed() {
        #expect(TabClosure.selectionAfterClosing(chat, selected: terminal, tabs: [terminal]) == terminal)
        #expect(TabClosure.selectionAfterClosing(chat, selected: nil, tabs: []) == nil)
    }

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
