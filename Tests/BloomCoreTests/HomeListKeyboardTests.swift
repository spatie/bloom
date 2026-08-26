import Foundation
import Testing
@testable import BloomCore

/// When Home's list is allowed to take first responder.
///
/// The bug behind every one of these is on `HomeListKeyboard`: the list claimed the keyboard from
/// a `.task`, the pane swaps between the empty state and the list as a search's two halves land,
/// and a swap builds a new table with a new `.task` on it. Typing two characters was enough to
/// have the list take the keyboard away from the search field the characters were going into.
@Suite("Home's list and the keyboard")
struct HomeListKeyboardTests {
    @Test("arriving at Home with nothing focused hands the list the keyboard")
    func arrivalClaims() {
        #expect(HomeListKeyboard.claims(searchFieldHasKeyboard: false, hasClaimed: false))
    }

    /// The reported bug. The user is mid word in the toolbar's search field when the results
    /// arrive and rebuild the table under him.
    @Test("a list built while the search field is being typed into does not claim")
    func searchFieldKeepsTheKeyboard() {
        #expect(!HomeListKeyboard.claims(searchFieldHasKeyboard: true, hasClaimed: false))
    }

    /// The other half of it: even with the field let go of, a table rebuilt by a filter moving is
    /// not somebody arriving at Home, so it gets no second offer.
    @Test("a rebuilt list does not claim again on the same visit")
    func rebuildDoesNotClaimAgain() {
        #expect(!HomeListKeyboard.claims(searchFieldHasKeyboard: false, hasClaimed: true))
        #expect(!HomeListKeyboard.claims(searchFieldHasKeyboard: true, hasClaimed: true))
    }

    /// The whole of a search, run through the rule in the order the events actually happen. The
    /// list is built four times and the keyboard is claimed once, before a character was typed.
    @Test("one claim survives a search that empties the pane and fills it again")
    func aWholeSearchClaimsOnce() {
        var hasClaimed = false

        func listAppeared(searchFieldHasKeyboard: Bool) -> Bool {
            let claims = HomeListKeyboard.claims(
                searchFieldHasKeyboard: searchFieldHasKeyboard, hasClaimed: hasClaimed
            )
            if claims { hasClaimed = true }
            return claims
        }

        // Home opens, nothing is focused, the list takes the keyboard so it can be arrowed.
        #expect(listAppeared(searchFieldHasKeyboard: false))
        // The user clicks into the search field and types the first character. Names still match,
        // so the table is not rebuilt and nothing is asked.
        // The second character matches no name, and the transcripts have not come back yet: the
        // pane goes to the empty state and the table is destroyed.
        // 120ms later sixteen transcript matches arrive and a new table is built.
        #expect(!listAppeared(searchFieldHasKeyboard: true))
        // A third character does the same again.
        #expect(!listAppeared(searchFieldHasKeyboard: true))
        // The user clicks a result, comes back, and clears the field. Still one visit.
        #expect(!listAppeared(searchFieldHasKeyboard: false))
    }
}
