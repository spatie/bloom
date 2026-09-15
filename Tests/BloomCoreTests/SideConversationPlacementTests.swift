import CoreGraphics
import Testing
@testable import BloomCore

@Suite("SideConversationPlacement")
struct SideConversationPlacementTests {
    private static let corner: CGFloat = 22
    private static let tail = SideConversationPlacement.tailSize

    /// A 28 point button near the foot of the pane, the box `ComposerControlLabel` draws.
    private func button(midX: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: midX - 14, y: bottom - 40, width: 28, height: 28)
    }

    @Test("A tall pane still hangs the card off the button, over the composer", arguments: [600.0, 900.0, 1400.0])
    func tall(height: Double) throws {
        let pane = CGSize(width: 1200, height: height)
        let anchor = button(midX: 600, bottom: height)
        let placement = SideConversationPlacement(pane: pane, anchor: anchor, cornerRadius: Self.corner)

        #expect(placement.frame.width == 560)
        #expect(placement.frame.midX == 600)
        // The tip is on the button's top edge, as NSPopover puts it, however much transcript shows.
        #expect(placement.frame.maxY == anchor.minY)
        #expect(placement.frame.height == 520 + Self.tail.height)
        let tailX = try #require(placement.tailX)
        #expect(placement.frame.minX + tailX == anchor.midX)
    }

    @Test("Clamped to the pane, the tail still points at the button", arguments: [880.0, 1150.0, 40.0])
    func clamped(midX: Double) throws {
        let pane = CGSize(width: 1200, height: 900)
        let anchor = button(midX: midX, bottom: 900)
        let placement = SideConversationPlacement(pane: pane, anchor: anchor, cornerRadius: Self.corner)

        #expect(placement.frame.minX >= SideConversationPlacement.margin)
        #expect(placement.frame.maxX <= pane.width - SideConversationPlacement.margin)
        #expect(placement.frame.maxY == anchor.minY)
        let tailX = try #require(placement.tailX)
        let inset = Self.corner + Self.tail.width / 2
        let expected = min(max(anchor.midX - placement.frame.minX, inset), placement.frame.width - inset)
        #expect(tailX == expected)
    }

    @Test("A narrow pane shrinks the card and keeps the tail on the button")
    func narrow() throws {
        let pane = CGSize(width: 320, height: 900)
        let anchor = button(midX: 250, bottom: 900)
        let placement = SideConversationPlacement(pane: pane, anchor: anchor, cornerRadius: Self.corner)

        #expect(placement.frame.width == 296)
        #expect(placement.frame.minX == 12)
        #expect(placement.frame.maxY == anchor.minY)
        let tailX = try #require(placement.tailX)
        #expect(placement.frame.minX + tailX == anchor.midX)
    }

    @Test("The tail stays clear of the rounded corner when the button is at the very edge")
    func cornerClear() throws {
        let pane = CGSize(width: 1200, height: 900)
        let anchor = button(midX: 1196, bottom: 900)
        let placement = SideConversationPlacement(pane: pane, anchor: anchor, cornerRadius: Self.corner)

        let tailX = try #require(placement.tailX)
        #expect(tailX == placement.frame.width - Self.corner - Self.tail.width / 2)
    }

    @Test("A short pane takes height off the card's top and leaves the tail on the button")
    func short() {
        let pane = CGSize(width: 1200, height: 420)
        let anchor = button(midX: 600, bottom: 420)
        let placement = SideConversationPlacement(pane: pane, anchor: anchor, cornerRadius: Self.corner)

        #expect(placement.frame.maxY == anchor.minY)
        #expect(placement.frame.minY == SideConversationPlacement.margin)
        #expect(placement.frame.height < 520 + Self.tail.height)
    }

    @Test("Without a button it falls back to the bottom trailing corner, with no tail")
    func unanchored() {
        let pane = CGSize(width: 1200, height: 900)
        let placement = SideConversationPlacement(pane: pane, anchor: nil, cornerRadius: Self.corner)

        #expect(placement.tailX == nil)
        #expect(placement.frame == CGRect(x: 1200 - 12 - 560, y: 900 - 12 - 520, width: 560, height: 520))
    }

    @Test("Without a button a short pane shrinks the card inside its margins")
    func unanchoredShort() {
        let placement = SideConversationPlacement(pane: CGSize(width: 1200, height: 300), anchor: nil, cornerRadius: Self.corner)

        #expect(placement.frame.minY == 12)
        #expect(placement.frame.maxY == 288)
    }

    @Test("A pane too small for the card gives it no negative size")
    func tiny() {
        let placement = SideConversationPlacement(
            pane: CGSize(width: 10, height: 10),
            anchor: CGRect(x: 0, y: 0, width: 10, height: 10),
            cornerRadius: Self.corner
        )
        #expect(placement.frame.width >= 0)
        #expect(placement.frame.height >= 0)
    }
}
