import Testing
@testable import BloomCore

struct MediaPreviewShortcutTests {
    @Test func spaceOverImageOpensPreview() {
        #expect(MediaPreviewShortcut.opens(
            keyCode: 49, hasModifiers: false, isRepeat: false, isOverImage: true, hasSheet: false
        ))
    }

    @Test(arguments: ["other key", "modifier", "repeat", "outside image", "sheet"])
    func unrelatedInputDoesNotOpenPreview(_ reason: String) {
        #expect(!MediaPreviewShortcut.opens(
            keyCode: reason == "other key" ? 0 : 49,
            hasModifiers: reason == "modifier",
            isRepeat: reason == "repeat",
            isOverImage: reason != "outside image",
            hasSheet: reason == "sheet"
        ))
    }
}
