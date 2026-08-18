import Testing
import Foundation
@testable import BatonCore

@Suite("GhosttySplitAppearance")
struct GhosttySplitAppearanceTests {
    @Test("every key is read")
    func reads() {
        let appearance = GhosttySplitAppearance.resolve(sources: ["""
        unfocused-split-opacity = 0.55
        unfocused-split-fill = #7a7a7a
        split-divider-color = #000000
        """])

        #expect(appearance.unfocusedOpacity == 0.55)
        #expect(appearance.unfocusedFill == GhosttyColor(red: 0x7A, green: 0x7A, blue: 0x7A))
        #expect(appearance.dividerColor == GhosttyColor(red: 0, green: 0, blue: 0))
    }

    @Test("a config with none of them leaves Baton's own dimming alone")
    func empty() {
        let appearance = GhosttySplitAppearance.resolve(sources: ["background = #fdf6e3"])

        #expect(appearance.isEmpty)
    }

    @Test("an opacity outside zero to one is ignored the way Ghostty ignores it",
          arguments: ["0", "-0.5", "1.5", "", "half"])
    func opacityRange(value: String) {
        let appearance = GhosttySplitAppearance.resolve(sources: ["unfocused-split-opacity = \(value)"])

        #expect(appearance.unfocusedOpacity == nil)
    }

    @Test("the last file wins, and a bare key resets")
    func precedence() {
        let appearance = GhosttySplitAppearance.resolve(sources: [
            "unfocused-split-opacity = 0.2\nunfocused-split-fill = #000000",
            "unfocused-split-opacity = 0.8\nunfocused-split-fill",
        ])

        #expect(appearance.unfocusedOpacity == 0.8)
        #expect(appearance.unfocusedFill == nil)
    }
}
