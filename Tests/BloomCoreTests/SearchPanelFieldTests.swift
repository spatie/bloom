import Foundation
import Testing
@testable import BloomCore

/// The panel's field: which mode what was typed puts it in, what is left of the text once the
/// prefix has been taken off, and what backing out of a mode restores.
///
/// The whole of this exists because the three move together. A `>` left in the text as well as in
/// the pill searches for a workspace called "> merge", and a mode left behind by an empty field
/// searches the menu bar for a workspace name.
@Suite("Search panel field")
struct SearchPanelFieldTests {
    @Test("a leading > switches to commands and is taken off the query")
    func theePrefixIsConsumed() {
        var field = SearchPanelField()
        field.type(">")
        #expect(field.mode == .commands)
        #expect(field.text.isEmpty)

        field.type("merge")
        #expect(field.mode == .commands)
        #expect(field.query == "merge")
    }

    /// `>merge` and `> merge` are the same query. One space after the prefix goes with it, and a
    /// second one is the user's.
    @Test("one space after the prefix goes with the prefix")
    func oneSpaceIsEaten() {
        var typed = SearchPanelField()
        typed.type("> merge")
        #expect(typed.query == "merge")

        var tight = SearchPanelField()
        tight.type(">merge")
        #expect(tight.query == "merge")

        var padded = SearchPanelField()
        padded.type(">  merge")
        #expect(padded.query == " merge")
    }

    /// A branch called `feature>thing` is a thing somebody can have, and a search that refused to
    /// look for it would be a search with a secret.
    @Test("a > that is not the first character is a character like any other")
    func onlyTheFirstCharacterCounts() {
        var field = SearchPanelField()
        field.type("feature>thing")
        #expect(field.mode == .things)
        #expect(field.query == "feature>thing")
    }

    @Test("a > typed inside commands is a character, not a second mode")
    func theePrefixIsReadOnceOnly() {
        var field = SearchPanelField()
        field.type(">")
        field.type(">merge")
        #expect(field.mode == .commands)
        #expect(field.query == ">merge")
    }

    @Test("backspace on an empty field leaves commands, and does nothing at rest")
    func backspaceLeavesTheMode() {
        var field = SearchPanelField()
        // Lifted out of `#expect`, which rewrites its argument into a closure taking the value
        // immutably. See CLAUDE.md: a mutating call inside the macro does not compile.
        let atRest = field.leaveMode()
        #expect(atRest == false)

        field.type(">")
        let left = field.leaveMode()
        #expect(left)
        #expect(field.mode == .things)
    }

    /// Backspace out of an action list must not be a way of losing what you typed to find the row
    /// you pushed into.
    @Test("leaving an action list puts the earlier query back")
    func leavingRestoresTheQuery() {
        var field = SearchPanelField()
        field.type("docs")
        let entered = field.enterActions(on: WorkspaceID("w1"))
        #expect(entered)
        #expect(field.mode == .actions(WorkspaceID("w1")))
        #expect(field.text.isEmpty)

        let left = field.leaveMode()
        #expect(left)
        #expect(field.mode == .things)
        #expect(field.query == "docs")
    }

    /// A command has no workspace of its own and an action list has no rows to push into, so
    /// neither can be pushed into again.
    @Test("only a search of things can be pushed into")
    func actionsAreEnteredFromThingsAlone() {
        var field = SearchPanelField()
        field.type(">")
        let entered = field.enterActions(on: WorkspaceID("w1"))
        #expect(entered == false)
        #expect(field.mode == .commands)
    }

    @Test("clearing empties the text and keeps the mode")
    func clearingKeepsTheMode() {
        var field = SearchPanelField()
        field.type(">")
        field.type("merge")
        field.clear()
        #expect(field.mode == .commands)
        #expect(field.isEmpty)
    }

    /// The chips split an answer about workspaces and transcripts, and neither of the other two
    /// modes has one to split.
    @Test("the scope chips are drawn while searching things and never in a mode")
    func onlyThingsHaveScopes() {
        #expect(SearchPanelMode.things.showsScopes)
        #expect(!SearchPanelMode.commands.showsScopes)
        #expect(!SearchPanelMode.actions(WorkspaceID("w1")).showsScopes)
        #expect(SearchPanelMode.things.pill == nil)
        #expect(SearchPanelMode.commands.pill == "Commands")
    }
}
