import Foundation
import Testing
@testable import BloomCore

/// Every key the panel answers, and the two answers that are not the same: a key it handled and a
/// key it ignored. An ignored key goes back to the field editor, where it still moves the caret or
/// types a character.
@Suite("Search panel keys")
struct SearchPanelKeysTests {
    private func context(
        mode: SearchPanelMode = .things,
        rows: Int = 5,
        highlighted: Int? = 0,
        isQueryEmpty: Bool = false,
        scope: HomeScope = .all,
        canDrill: Bool = true,
        caretAtEnd: Bool = true
    ) -> SearchPanelKeyContext {
        SearchPanelKeyContext(
            mode: mode,
            rowCount: rows,
            highlighted: highlighted,
            isQueryEmpty: isQueryEmpty,
            scope: scope,
            scopes: HomeScope.offered(searching: true),
            canDrill: canDrill,
            caretAtEnd: caretAtEnd
        )
    }

    /// `ListNavigation`'s rule and the platform's: Down on the last row stays on the last row. A
    /// list that jumped back to the top would move the reader's eye the height of the card on a
    /// keystroke that means "one more".
    @Test("the arrows stop at both ends rather than wrapping")
    func arrowsDoNotWrap() {
        #expect(SearchPanelKeys.outcome(for: .down, in: context(highlighted: 0)) == .move(1))
        #expect(SearchPanelKeys.outcome(for: .down, in: context(highlighted: 4)) == .handled)
        #expect(SearchPanelKeys.outcome(for: .up, in: context(highlighted: 0)) == .handled)
        #expect(SearchPanelKeys.outcome(for: .up, in: context(highlighted: 3)) == .move(2))
    }

    /// An arrow handed back would scroll whatever is behind the card, which is the window the
    /// panel is supposed to leave exactly where it was.
    @Test("an arrow with nowhere to go is still the panel's")
    func arrowsAreNeverHandedBack() {
        #expect(SearchPanelKeys.outcome(for: .down, in: context(rows: 0, highlighted: nil)) == .handled)
    }

    @Test("with nothing highlighted, an arrow enters the list from the edge it came from")
    func arrowsEnterFromTheEdge() {
        #expect(SearchPanelKeys.outcome(for: .down, in: context(highlighted: nil)) == .move(0))
        #expect(SearchPanelKeys.outcome(for: .up, in: context(highlighted: nil)) == .move(4))
    }

    @Test("Tab steps the chips forward and Shift+Tab back, wrapping")
    func tabWalksTheChips() {
        let scopes = HomeScope.offered(searching: true)
        #expect(SearchPanelKeys.outcome(for: .tab, in: context(scope: .all)) == .scope(scopes[1]))
        #expect(SearchPanelKeys.outcome(for: .backTab, in: context(scope: .all)) == .scope(scopes[3]))
        #expect(SearchPanelKeys.outcome(for: .tab, in: context(scope: scopes[3])) == .scope(scopes[0]))
    }

    /// Commands and an action list have no answer to split, so Tab goes back to the field editor
    /// and moves the focus the way it does everywhere else.
    @Test("Tab is not the panel's in a mode")
    func tabIsHandedBackInAMode() {
        #expect(SearchPanelKeys.outcome(for: .tab, in: context(mode: .commands)) == .ignored)
        #expect(
            SearchPanelKeys.outcome(
                for: .tab, in: context(mode: .actions(WorkspaceID("w1")))
            ) == .ignored
        )
    }

    @Test("Return opens the highlighted row, and does nothing when there is none")
    func returnOpens() {
        #expect(SearchPanelKeys.outcome(for: .returnKey, in: context()) == .open)
        #expect(SearchPanelKeys.outcome(for: .returnKey, in: context(highlighted: nil)) == .handled)
    }

    @Test("Cmd+Return pushes into a row that has a menu, and is swallowed by one that has not")
    func commandReturnDrills() {
        #expect(SearchPanelKeys.outcome(for: .commandReturn, in: context()) == .drill)
        #expect(
            SearchPanelKeys.outcome(for: .commandReturn, in: context(canDrill: false)) == .handled
        )
    }

    /// Mid word the right arrow is the caret's. A panel that took it would make the field unusable
    /// for correcting a typo.
    @Test("the right arrow pushes in only from the end of the field")
    func rightNeedsTheCaretAtTheEnd() {
        #expect(SearchPanelKeys.outcome(for: .right, in: context()) == .drill)
        #expect(SearchPanelKeys.outcome(for: .right, in: context(caretAtEnd: false)) == .ignored)
        #expect(SearchPanelKeys.outcome(for: .right, in: context(canDrill: false)) == .ignored)
    }

    /// Somebody who typed a query and wants a different one should not have to reopen the panel to
    /// get an empty field, and somebody who wants out presses it twice.
    @Test("Escape clears a full field and closes an empty one")
    func escapeClearsThenCloses() {
        #expect(SearchPanelKeys.outcome(for: .escape, in: context(isQueryEmpty: false)) == .clearQuery)
        #expect(SearchPanelKeys.outcome(for: .escape, in: context(isQueryEmpty: true)) == .close)
    }

    @Test("Backspace on an empty field leaves a mode and is otherwise the field's")
    func backspaceLeavesAMode() {
        #expect(SearchPanelKeys.outcome(for: .backspaceOnEmpty, in: context()) == .ignored)
        #expect(
            SearchPanelKeys.outcome(for: .backspaceOnEmpty, in: context(mode: .commands)) == .leaveMode
        )
        #expect(
            SearchPanelKeys.outcome(
                for: .backspaceOnEmpty, in: context(mode: .actions(WorkspaceID("w1")))
            ) == .leaveMode
        )
    }

    /// The two footers that differ are the ones that matter: at rest the prefix is advertised
    /// because there are no chips to advertise, and Backspace is named in both modes because it is
    /// the only way out of one.
    @Test("the footer names the way out of every mode")
    func theFooterNamesTheWayOut() {
        let resting = SearchPanelKeys.footer(for: .things, isSearching: false)
        #expect(resting.contains { $0.key == ">" })
        let searching = SearchPanelKeys.footer(for: .things, isSearching: true)
        #expect(searching.contains { $0.label == "Scope" })
        #expect(SearchPanelKeys.footer(for: .commands, isSearching: true).contains { $0.label == "Leave commands" })
        #expect(
            SearchPanelKeys.footer(for: .actions(WorkspaceID("w1")), isSearching: true)
                .contains { $0.label == "Back" }
        )
    }
}
