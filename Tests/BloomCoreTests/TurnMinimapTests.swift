import Testing
@testable import BloomCore

@Suite("Turn minimap")
struct TurnMinimapTests {
    @Test("Two turns are not worth a map")
    func tooFewTurns() {
        #expect(TurnMinimap(turns: 2, height: 500) == nil)
        #expect(TurnMinimap(turns: 3, height: 500) != nil)
    }

    @Test("With room, marks take the preferred step")
    func preferredPitch() throws {
        let map = try #require(TurnMinimap(turns: 10, height: 500))
        #expect(map.pitch == TurnMinimap.preferredPitch)
        #expect(map.length == 80)
    }

    @Test("A long conversation tightens the step to fit the height")
    func tightens() throws {
        let map = try #require(TurnMinimap(turns: 200, height: 400))
        #expect(map.pitch == 2)
        #expect(map.length == 400)
    }

    @Test("Too many turns for the height to tell apart is no map")
    func tooTight() {
        #expect(TurnMinimap(turns: 1_000, height: 400) == nil)
    }

    @Test("A point finds the mark it is over, and clamps past either end")
    func hitTesting() throws {
        let map = try #require(TurnMinimap(turns: 5, height: 500))
        #expect(map.index(at: 0) == 0)
        #expect(map.index(at: 7.9) == 0)
        #expect(map.index(at: 8) == 1)
        #expect(map.index(at: 39) == 4)
        #expect(map.index(at: -20) == 0)
        #expect(map.index(at: 900) == 4)
        #expect(map.centre(of: 1) == 12)
    }

    @Test("It fits only in a margin wide enough beside the column")
    func fits() {
        #expect(!TurnMinimap.fits(paneWidth: 600, measure: 760))
        #expect(!TurnMinimap.fits(paneWidth: 820, measure: 760))
        #expect(TurnMinimap.fits(paneWidth: 760 + 2 * 36, measure: 760))
    }

    @Test("The current turn is the last one starting at or above the top of the screen")
    func current() {
        let seqs = [3, 10, 42]
        #expect(TurnMinimap.current(in: seqs, topmost: 1) == nil)
        #expect(TurnMinimap.current(in: seqs, topmost: 3) == 0)
        #expect(TurnMinimap.current(in: seqs, topmost: 41) == 1)
        #expect(TurnMinimap.current(in: seqs, topmost: 900) == 2)
        #expect(TurnMinimap.current(in: [], topmost: 5) == nil)
    }
}
