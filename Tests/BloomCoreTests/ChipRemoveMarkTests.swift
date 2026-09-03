import Foundation
import Testing
@testable import BloomCore

/// What is asserted here is the *relationship*, never a particular point size, because the four
/// chips that draw this control are drawn at whatever slot each one holds and the bug was that
/// they disagreed. A glyph that fills its disc is the smudge again; a glyph that vanishes in it is
/// a chip with a dot on it.
@Suite("The close control on a chip")
struct ChipRemoveMarkTests {
    @Test("the X is over half the disc and never fills it")
    func glyphLeavesPlateAround() {
        for diameter in stride(from: CGFloat(10), through: 24, by: 1) {
            let glyph = ChipRemoveMark.glyphPointSize(diameter: diameter)
            #expect(glyph > diameter / 2)
            #expect(glyph < diameter)
        }
    }

    /// The two renderers ask for the same size at the same slot, which is the whole reason these
    /// numbers left the views. A ratio scales; a constant copied into a second file does not.
    @Test("the size follows the slot rather than a number written twice")
    func glyphScalesWithDiameter() {
        #expect(ChipRemoveMark.glyphPointSize(diameter: 28) == ChipRemoveMark.glyphPointSize(diameter: 14) * 2)
        #expect(ChipRemoveMark.glyphPointSize(diameter: 0) == 0)
    }

    /// On an accent fill the plate is a wash of the inverted ink, and the pointer lifts it. Both
    /// have to stay a wash: at one it is a white disc on a blue bubble, which is the card lying on
    /// the fill that every other chip on that ground was written to avoid.
    @Test("the plate on an emphasized fill lifts under the pointer and stays a wash")
    func emphasisPlateLifts() {
        #expect(ChipRemoveMark.emphasisPlateHovered > ChipRemoveMark.emphasisPlate)
        #expect(ChipRemoveMark.emphasisPlate > 0)
        #expect(ChipRemoveMark.emphasisPlateHovered < 1)
        #expect(ChipRemoveMark.emphasisRing > ChipRemoveMark.emphasisPlateHovered)
        #expect(ChipRemoveMark.emphasisRing < 1)
    }
}
