import Testing
@testable import BloomCore

/// The in-place rename that never committed when you clicked away, and that the sidebar threw away
/// whenever the selection moved.
@Suite("Ending an in-place rename")
struct InPlaceRenameTests {
    /// The fix, stated: everything but Escape keeps what was typed. Finder, Xcode and Mail all
    /// commit on losing first responder.
    @Test("every ending but Escape writes the name")
    func endingsThatCommit() {
        for ending in InPlaceRename.Ending.allCases where ending != .escaped {
            #expect(
                InPlaceRename.outcome(ending, draft: "new name", current: "old name")
                    == .commit("new name"),
                "\(ending)"
            )
        }
    }

    /// Including the one the sidebar used to lose: the list closing the field because the
    /// selection moved to another workspace.
    @Test("a field closed from underneath still writes")
    func dismissed() {
        #expect(
            InPlaceRename.outcome(.dismissed, draft: "renamed", current: "old")
                == .commit("renamed")
        )
    }

    @Test("Escape throws the draft away")
    func escape() {
        #expect(InPlaceRename.outcome(.escaped, draft: "typed", current: "old") == .discard)
    }

    @Test("surrounding space is not part of the name")
    func trimming() {
        #expect(
            InPlaceRename.outcome(.submitted, draft: "  spaced  ", current: "old")
                == .commit("spaced")
        )
        #expect(InPlaceRename.outcome(.focusLost, draft: "   ", current: "old") == .discard)
        #expect(InPlaceRename.outcome(.submitted, draft: "", current: "old") == .discard)
    }

    /// A name that came back unchanged is not a rename, so it costs no write and no reflow. The
    /// trim runs first, which is what makes "old " unchanged rather than new.
    @Test("an unchanged name writes nothing")
    func unchanged() {
        #expect(InPlaceRename.outcome(.submitted, draft: "old", current: "old") == .discard)
        #expect(InPlaceRename.outcome(.focusLost, draft: " old ", current: "old") == .discard)
    }
}
