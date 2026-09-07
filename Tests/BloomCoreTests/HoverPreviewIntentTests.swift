import Testing
@testable import BloomCore

struct HoverPreviewIntentTests {
    @Test func hoverSpacePreviewsButTypingDisarmsUntilPointerMoves() {
        var intent = HoverPreviewIntent()
        let first = intent.keyPressed(
            keyCode: 49, hasModifiers: false, isRepeat: false,
            pointerMoved: true, isOverFile: true, hasSheet: false
        )
        #expect(first)
        let letter = intent.keyPressed(
            keyCode: 0, hasModifiers: false, isRepeat: false,
            pointerMoved: false, isOverFile: true, hasSheet: false
        )
        #expect(!letter)
        let typedSpace = intent.keyPressed(
            keyCode: 49, hasModifiers: false, isRepeat: false,
            pointerMoved: false, isOverFile: true, hasSheet: false
        )
        #expect(!typedSpace)
        let deliberatePreview = intent.keyPressed(
            keyCode: 49, hasModifiers: false, isRepeat: false,
            pointerMoved: true, isOverFile: true, hasSheet: false
        )
        #expect(deliberatePreview)
    }

    @Test(arguments: ["other key", "modifier", "repeat", "outside file", "sheet"])
    func unrelatedInputDoesNotOpenPreview(_ reason: String) {
        var intent = HoverPreviewIntent()
        let opens = intent.keyPressed(
            keyCode: reason == "other key" ? 0 : 49,
            hasModifiers: reason == "modifier", isRepeat: reason == "repeat", pointerMoved: true,
            isOverFile: reason != "outside file", hasSheet: reason == "sheet"
        )
        #expect(!opens)
    }
}
