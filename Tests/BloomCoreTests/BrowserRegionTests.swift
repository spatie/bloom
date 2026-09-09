import Foundation
import Testing
@testable import BloomCore

@Suite("Browser region feedback")
struct BrowserRegionTests {
    @Test("Moving a selection preserves its size and stops at each image edge")
    func moveSelection() {
        let selection = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        #expect(BrowserRegion.moved(selection, by: CGSize(width: -1, height: -1))
            == CGRect(x: 0, y: 0, width: 0.4, height: 0.5))
        #expect(BrowserRegion.moved(selection, by: CGSize(width: 1, height: 1))
            == CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5))
        #expect(BrowserRegion.moved(CGRect(x: 0, y: 0, width: 1, height: 1), by: CGSize(width: 1, height: -1))
            == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("Each resize handle keeps its opposite corner fixed", arguments: BrowserRegion.Corner.allCases)
    func resizeSelection(corner: BrowserRegion.Corner) {
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let point = CGPoint(x: corner.isLeft ? 0 : 1, y: corner.isTop ? 0 : 1)
        let resized = BrowserRegion.resized(selection, corner: corner, to: point)
        #expect(resized.width == 0.75)
        #expect(resized.height == 0.75)
        #expect(corner.isLeft ? resized.maxX == selection.maxX : resized.minX == selection.minX)
        #expect(corner.isTop ? resized.maxY == selection.maxY : resized.minY == selection.minY)
    }

    @Test("Handles cannot cross the opposite corner or escape the screenshot")
    func clampsResize() {
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let crossed = BrowserRegion.resized(selection, corner: .topLeft, to: CGPoint(x: 2, y: 2))
        #expect(abs(crossed.width - 0.01) < 0.0001)
        #expect(abs(crossed.height - 0.01) < 0.0001)
        #expect(crossed.maxX == selection.maxX && crossed.maxY == selection.maxY)
        let expanded = BrowserRegion.resized(selection, corner: .bottomRight, to: CGPoint(x: 2, y: 2))
        #expect(expanded.maxX == 1 && expanded.maxY == 1)
        let tiny = BrowserRegion.resized(CGRect(x: 0, y: 0, width: 0.005, height: 0.005), corner: .topLeft, to: .zero)
        #expect(tiny.origin == .zero && tiny.width > 0 && tiny.height > 0)
    }

    @Test("Letterboxing keeps the screenshot's aspect ratio")
    func fitsImage() {
        let frame = BrowserRegion.imageFrame(
            image: CGSize(width: 1600, height: 900), canvas: CGSize(width: 800, height: 600)
        )
        #expect(frame == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(BrowserRegion.imageFrame(image: .zero, canvas: CGSize(width: 800, height: 600)) == .zero)
    }

    @Test("Dragging in either direction selects the same pixels", arguments: [false, true])
    func reverseDrag(reversed: Bool) throws {
        let first = CGPoint(x: 100, y: 100)
        let second = CGPoint(x: 300, y: 250)
        let frame = CGRect(x: 0, y: 75, width: 800, height: 450)
        let selection = try #require(BrowserRegion.selection(
            from: reversed ? second : first, to: reversed ? first : second, in: frame
        ))
        #expect(BrowserRegion.pixels(selection, image: CGSize(width: 1600, height: 900))
            == CGRect(x: 200, y: 50, width: 400, height: 300))
    }

    @Test("Dragging past the screenshot stops at its edges")
    func clipsDrag() throws {
        let selection = try #require(BrowserRegion.selection(
            from: CGPoint(x: 50, y: 50), to: CGPoint(x: -100, y: 200),
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))
        #expect(selection == CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }

    @Test("Clicks, thin slivers and drags starting in the letterbox do not make attachments")
    func rejectsEmptySelections() {
        let frame = CGRect(x: 0, y: 75, width: 800, height: 450)
        #expect(BrowserRegion.selection(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 200), in: frame) == nil)
        #expect(BrowserRegion.selection(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), in: frame) == nil)
        #expect(BrowserRegion.selection(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 200), in: frame) == nil)
    }

    @Test("Resizing moves the selection outline without changing which source pixels are attached")
    func resizePreservesCrop() throws {
        let image = CGSize(width: 1200, height: 800)
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let frame = BrowserRegion.imageFrame(image: image, canvas: CGSize(width: 300, height: 300))
        let outline = BrowserRegion.rect(selection, in: frame)
        #expect(outline == CGRect(x: 75, y: 100, width: 150, height: 100))
        let redrawn = try #require(BrowserRegion.selection(
            from: outline.origin, to: CGPoint(x: outline.maxX, y: outline.maxY), in: frame
        ))
        #expect(BrowserRegion.pixels(redrawn, image: image) == CGRect(x: 300, y: 200, width: 600, height: 400))
    }

    @Test("Crop rounding includes edge pixels and stays inside the image")
    func roundsPixels() {
        let image = CGSize(width: 100, height: 100)
        #expect(BrowserRegion.pixels(CGRect(x: 0.105, y: 0.205, width: 0.2, height: 0.3), image: image)
            == CGRect(x: 10, y: 20, width: 21, height: 31))
        #expect(BrowserRegion.pixels(CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), image: image)
            == CGRect(x: 90, y: 90, width: 10, height: 10))
        #expect(BrowserRegion.pixels(CGRect(x: 2, y: 2, width: 1, height: 1), image: image) == nil)
        #expect(BrowserRegion.pixels(.zero, image: image) == nil)
    }

    @Test("The draft keeps the comment, exact page URL and a recognised attachment together")
    func draftCarriesContext() {
        let path = ".bloom/attachments/ABC/Selected area.png"
        let address = "http://localhost:3100/settings?tab=profile#avatar"
        let draft = BrowserRegion.draft(comment: "  Give this more space.\nKeep it aligned. \n", address: address, paths: [path])
        #expect(draft == "Give this more space.\nKeep it aligned.\nPage: \(address)\n`\(path)`")
        #expect(AttachmentDraft.parse(draft).paths == [path])
    }

    @Test("Region capture needs a page and waits for other captures")
    func toolbarAvailability() {
        let page = BrowserTabTitle.BrowserPage(address: "http://localhost:3100", title: "Preview")
        #expect(!BrowserToolbar().regionCapture.isEnabled)
        #expect(BrowserToolbar(page: page).regionCapture.isEnabled)
        #expect(!BrowserToolbar(page: page, isCapturing: true).regionCapture.isEnabled)
    }
}
