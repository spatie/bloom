import Testing
@testable import BloomCore

/// The centre column's tab strip, drawn the way Safari draws its tab bar.
///
/// It was drawn for a single tab as well, because the `+` that opens a terminal or a browser lived
/// at its end. That `+` moved to the title bar, so a strip of one says nothing the title does not.
@Suite("When the tab strip is drawn")
struct TabStripVisibilityTests {
    @Test("one tab showing one pane hides the strip")
    func singleTab() {
        #expect(!TabStripVisibility.isShown(tabCount: 1, paneCount: 1))
    }

    @Test("a second tab brings the strip back")
    func secondTab() {
        #expect(TabStripVisibility.isShown(tabCount: 2, paneCount: 1))
        #expect(TabStripVisibility.isShown(tabCount: 5, paneCount: 1))
    }

    @Test("a single tab split into panes keeps the strip")
    func splitTab() {
        #expect(TabStripVisibility.isShown(tabCount: 1, paneCount: 2))
        #expect(TabStripVisibility.isShown(tabCount: 2, paneCount: 3))
    }

    @Test("a workspace with no tab has no strip")
    func noTab() {
        #expect(!TabStripVisibility.isShown(tabCount: 0, paneCount: 1))
        #expect(!TabStripVisibility.isShown(tabCount: 0, paneCount: 1, isRenaming: true))
    }

    @Test("renaming a lone tab shows the strip for as long as the field is open")
    func renaming() {
        #expect(TabStripVisibility.isShown(tabCount: 1, paneCount: 1, isRenaming: true))
    }
}
