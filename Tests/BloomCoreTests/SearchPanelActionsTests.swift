import Foundation
import Testing
@testable import BloomCore

/// The list Cmd+Return pushes into: one workspace's own menu, gated by the same rule the sidebar,
/// Home and the menu bar are gated by.
@Suite("Search panel actions")
struct SearchPanelActionsTests {
    /// Fourteen items for free, and none of them has to be listed at the top level.
    @Test("a live workspace is offered its whole row menu, in the row menu's order")
    func aLiveWorkspace() {
        let rows = SearchPanelActions.rows(for: .live(WorkspaceID("w1")))
        #expect(rows.map(\.item.action) == [
            .openInEditor, .revealInFinder, .copyName, .copyBranchName,
            .pin, .unreadMark, .renameWorkspace, .archive,
        ])
    }

    /// Opening an editor on a path that is not there means nothing, and neither does archiving
    /// what is already archived. `WorkspaceMenuSubject` is the one table that says so.
    @Test("an archived workspace is offered what Home offers it and nothing more")
    func anArchivedWorkspace() {
        let rows = SearchPanelActions.rows(for: .archived(WorkspaceID("w1")))
        #expect(rows.map(\.item.action) == [.copyName, .copyBranchName, .restore])
    }

    /// The pill in the field already names what is being acted on, and a heading repeating it
    /// would be the same words twice on one card.
    @Test("the action list is one section with no heading")
    func oneSectionNoHeading() {
        let sections = SearchPanelActions.sections(for: .live(WorkspaceID("w1")))
        #expect(sections.count == 1)
        #expect(sections[0].title == nil)
    }

    /// Every row is a menu bar row, so the panel and the bar cannot word one action two ways or
    /// print two different keys for it.
    @Test("every workspace menu action names a row in the catalogue, and the map goes both ways")
    func theMapIsComplete() {
        for action in WorkspaceMenuAction.allCases {
            let menuBar = SearchPanelActions.menuBarAction(for: action)
            #expect(MenuBarCatalogue[menuBar].menu == .workspace)
            #expect(SearchPanelActions.workspaceAction(for: menuBar) == action)
        }
    }

    /// Colour is a submenu of ten swatches rather than an action, so a row that ran it would have
    /// nothing to run. It is still in the Workspace menu and still reachable through `>`.
    @Test("the colour submenu is not offered as a row")
    func colourIsNotARow() {
        let offered = SearchPanelActions.rows(for: .live(WorkspaceID("w1"))).map(\.item.action)
        #expect(!offered.contains(.colour))
        #expect(!SearchPanelActions.order.contains(.colour))
    }
}
