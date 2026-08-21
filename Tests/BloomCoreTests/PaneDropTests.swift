import Foundation
import Testing
@testable import BloomCore

/// One string is both a tab id and a pane id in an unsplit tab, so a drop has to say which it is.
@Suite("PaneDrop")
struct PaneDropTests {
    @Test("a tab travels as its bare id, exactly as it always has")
    func tabIsBare() {
        #expect(PaneDrop.tab("abc").encoded == "abc")
        #expect(PaneDrop(encoded: "abc") == .tab("abc"))
    }

    @Test("a pane says that it is one")
    func paneIsMarked() {
        let encoded = PaneDrop.pane("abc").encoded
        #expect(encoded != "abc")
        #expect(PaneDrop(encoded: encoded) == .pane("abc"))
    }

    /// The case that made this necessary: a split tab's root pane carries the tab's own id, so the
    /// two drops would otherwise be the same eleven bytes.
    @Test("the same id means two different things depending on what carried it")
    func sameIDTwoMeanings() {
        let id = "7f3a1c2e"
        #expect(PaneDrop(encoded: PaneDrop.tab(id).encoded) == .tab(id))
        #expect(PaneDrop(encoded: PaneDrop.pane(id).encoded) == .pane(id))
    }

    /// Anything let go over a pane from outside the app arrives as a bare string, and has to keep
    /// reading as a tab id so it can go on failing the membership check the caller already makes.
    @Test("text from another app reads as a tab id and nothing else")
    func strangerIsATab() {
        #expect(PaneDrop(encoded: "https://example.com") == .tab("https://example.com"))
        #expect(PaneDrop(encoded: "") == .tab(""))
        #expect(PaneDrop(encoded: "https://example.com").movedPane == nil)
    }

    @Test("only a pane names a pane to move")
    func movedPane() {
        #expect(PaneDrop.pane("abc").movedPane == "abc")
        #expect(PaneDrop.tab("abc").movedPane == nil)
    }

    /// A stranger that happens to wear the mark reads as a pane move, and then names a pane the
    /// tab does not have, so the caller refuses it there. The mark is not a trust boundary and is
    /// not asked to be one: it separates two of this app's own drags, and every drop is still
    /// checked against what the tab actually holds.
    @Test("a stranger wearing the mark still has to name a pane that exists")
    func strangerWearingTheMark() {
        #expect(PaneDrop(encoded: "bloom.pane:nonsense") == .pane("nonsense"))
    }

    @Test("every drop survives the round trip it is put through")
    func roundTrip() {
        for drop in [PaneDrop.tab("a"), .pane("a"), .tab("bloom.pane"), .pane("bloom.pane:")] {
            #expect(PaneDrop(encoded: drop.encoded) == drop)
        }
    }
}
