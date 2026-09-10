import Testing
@testable import BloomCore

struct BrowserViewportTests {
    @Test func desktopFitsWithoutChangingLayoutDimensions() {
        var viewport = BrowserViewport()
        viewport.isEnabled = true
        viewport.select(.desktop)
        #expect(viewport.scale(availableWidth: 720, availableHeight: 600) == 0.5)
        #expect(viewport.width == 1440)
        #expect(viewport.height == 900)
        viewport.fitsPane = false
        #expect(viewport.scale(availableWidth: 720, availableHeight: 600) == 1)
    }

    @Test func phoneFitsHeightAndNeverEnlarges() {
        var viewport = BrowserViewport()
        viewport.isEnabled = true
        #expect(viewport.scale(availableWidth: 1000, availableHeight: 422) == 0.5)
        #expect(viewport.scale(availableWidth: 1000, availableHeight: 2000) == 1)
        #expect(viewport.scale(availableWidth: -10, availableHeight: 0) > 0)
    }

    @Test func toggleAndRotationPreserveCustomSize() {
        var viewport = BrowserViewport()
        viewport.resize(width: 412, height: 915)
        viewport.isEnabled = true
        viewport.isEnabled = false
        #expect(viewport.width == 412)
        #expect(viewport.height == 915)
        #expect(viewport.preset == nil)
        viewport.rotate()
        #expect(viewport.width == 915)
        #expect(viewport.height == 412)
    }

    @Test func savedCustomSizesSurvivePresetChangesWithoutDuplicates() {
        var viewport = BrowserViewport()
        viewport.saveSize()
        #expect(viewport.savedSizes.isEmpty)
        viewport.resize(width: 412, height: 915)
        viewport.saveSize()
        viewport.saveSize()
        viewport.select(.desktop)
        #expect(viewport.savedSizes.count == 1)
        #expect(viewport.savedSizes.first?.width == 412)
        #expect(viewport.savedSizes.first?.height == 915)
        viewport.removeSavedSizes()
        #expect(viewport.savedSizes.isEmpty)
    }

    @Test func invalidDimensionsAreBounded() {
        var viewport = BrowserViewport()
        viewport.resize(width: -5, height: Int.max)
        #expect(viewport.width == 240)
        #expect(viewport.height == 3840)
    }
}
