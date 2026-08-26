import Foundation
import Testing
@testable import BloomCore

/// Which tabs can be given a name, asked by the tab's own menu and by the File menu's Rename Tab.
/// It was the tab's alone, written inside a view, until a menu bar item had to grey against the
/// same answer.
@Suite("TabRenaming")
struct TabRenamingTests {
    private let chat = PaneContent.chat(SessionID(rawValue: "s-one"))
    private let tool = PaneContent.tool("t-one")

    @Test("a conversation always has a name to change")
    func chatRenames() {
        #expect(TabRenaming.canRename(chat, tabKind: nil))
    }

    @Test("a shell and a page carry a name somebody chose")
    func toolsRename() {
        #expect(TabRenaming.canRename(tool, tabKind: .terminal))
        #expect(TabRenaming.canRename(tool, tabKind: .browser))
    }

    /// Both are named after what they show and there is exactly one of each per workspace, so a
    /// name written on either is thrown away by the next reopen.
    @Test("the review and the notes have no name of their own")
    func theFixedTitles() {
        #expect(!TabRenaming.canRename(tool, tabKind: .review))
        #expect(!TabRenaming.canRename(tool, tabKind: .notes))
    }

    /// The same answer `PaneSplit` gives a pointer at a tab that has gone, so the menu greys
    /// rather than opening a field on nothing.
    @Test("a tab that is no longer open cannot be renamed")
    func missingTab() {
        #expect(!TabRenaming.canRename(tool, tabKind: nil))
    }

    @Test("every kind is decided, so a new one cannot arrive renameable by default")
    func everyKindIsAnswered() {
        let renameable = CenterTabKind.allCases.filter { TabRenaming.canRename(tool, tabKind: $0) }
        #expect(Set(renameable) == [.terminal, .browser])
    }
}
