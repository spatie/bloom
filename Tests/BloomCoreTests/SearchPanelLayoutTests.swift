import CoreGraphics
import Testing
@testable import BloomCore

/// How wide the panel comes out at the widths this window is actually opened at, and what happens
/// at both ends of the clamp.
@Suite("Search panel layout")
struct SearchPanelLayoutTests {
    @Test("A window at the scene's own default gets a panel wider than the old constant")
    func defaultWindow() {
        let width = SearchPanelLayout.width(inWindow: 1_440)
        #expect(width == 1_440 * SearchPanelLayout.proportion)
        #expect(width > SearchPanelLayout.minimumWidth)
    }

    @Test("A wide window is clamped rather than left to grow")
    func wideWindow() {
        #expect(SearchPanelLayout.width(inWindow: 2_560) == SearchPanelLayout.maximumWidth)
        #expect(SearchPanelLayout.width(inWindow: 3_440) == SearchPanelLayout.maximumWidth)
    }

    @Test("The narrowest window this one can be still gets the width the panel has always had")
    func narrowWindow() {
        // Both ends of `WindowWidths.minimum`: with the inspector on screen and without it.
        #expect(SearchPanelLayout.width(inWindow: 1_122) == SearchPanelLayout.minimumWidth)
        #expect(SearchPanelLayout.width(inWindow: 841) == SearchPanelLayout.minimumWidth)
    }

    @Test("The panel never comes out narrower than it was before it answered the window")
    func neverNarrower() {
        for width in stride(from: CGFloat(0), through: 4_000, by: 20) {
            #expect(SearchPanelLayout.width(inWindow: width) >= SearchPanelLayout.minimumWidth)
        }
    }

    @Test("The panel never comes out wider than the window it is drawn in")
    func neverWiderThanTheWindow() {
        for width in stride(from: CGFloat(841), through: 4_000, by: 20) {
            #expect(SearchPanelLayout.width(inWindow: width) <= width)
        }
    }

    @Test("There is a real margin either side at every width this window can reach")
    func keepsItsMargins() {
        for width in stride(from: CGFloat(841), through: 4_000, by: 20) {
            let panel = SearchPanelLayout.width(inWindow: width)
            #expect((width - panel) / 2 >= SearchPanelLayout.margin)
        }
    }

    @Test("The width answers the window and nothing else, so typing cannot move it")
    func onlyTheWindowMovesIt() {
        #expect(SearchPanelLayout.width(inWindow: 1_730) == SearchPanelLayout.width(inWindow: 1_730))
        #expect(SearchPanelLayout.width(inWindow: 1_730) > SearchPanelLayout.width(inWindow: 1_440))
    }
}
