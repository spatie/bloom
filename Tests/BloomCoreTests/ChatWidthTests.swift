import Foundation
import Testing
@testable import BloomCore

struct ChatWidthTests {
    @Test("Comfortable preserves the existing reading measures")
    func comfortable() {
        #expect(ChatWidth.comfortable.measures() == .init(conversation: 760, prose: 680))
    }

    @Test("Wide gives structured content more room than paragraphs")
    func wide() {
        #expect(ChatWidth.wide.measures() == .init(conversation: 1100, prose: 960))
    }

    @Test("Full leaves the column uncapped while keeping readable paragraphs")
    func full() {
        #expect(ChatWidth.full.measures().conversation == .infinity)
        #expect(ChatWidth.full.measures().prose == 960)
    }

    @Test("Disabling the prose cap leaves each mode's conversation width intact", arguments: ChatWidth.allCases)
    func noParagraphCap(width: ChatWidth) {
        #expect(width.measures(limitsProse: false).prose == .infinity)
        #expect(width.measures(limitsProse: false).conversation == width.measures().conversation)
    }

    @Test("A setting change invalidates heights even when the pane stays the same width",
          arguments: [ChatWidth.wide.measures(), ChatWidth.full.measures(), ChatWidth.comfortable.measures(limitsProse: false)])
    func invalidatesAtSamePaneWidth(measures: ChatWidth.Measures) {
        var heights = TranscriptRowHeights()
        let key = TranscriptContentKey { $0.combine("paragraph") }
        heights.reset(width: 1440, scale: 1, leading: 1.7)
        heights.note(320, for: key, measuredAt: 1440)
        let changed = heights.reset(width: 1440, scale: 1, leading: 1.7, chatMeasures: measures)
        #expect(changed)
        #expect(heights.height(for: key) == nil)
    }

    @Test("Pane resizes keep the chosen measures and unchanged settings retain cached heights")
    func resizing() {
        var heights = TranscriptRowHeights()
        let measures = ChatWidth.full.measures(limitsProse: false)
        heights.reset(width: 1440, scale: 1, leading: 1.7, chatMeasures: measures)
        let resized = heights.rewidth(to: 480)
        #expect(resized)
        #expect(heights.measure?.chatMeasures == measures)
        let key = TranscriptContentKey { $0.combine("paragraph") }
        heights.note(640, for: key, measuredAt: 480)
        let reset = heights.reset(width: 480, scale: 1, leading: 1.7, chatMeasures: measures)
        #expect(!reset)
        #expect(heights.height(for: key) == 640)
    }

    @Test("Reading measure changes retain the document geometry as stale estimates",
          arguments: [ChatWidth.wide.measures(), ChatWidth.full.measures(), ChatWidth.full.measures(limitsProse: false)])
    func reflowKeepsGeometry(measures: ChatWidth.Measures) {
        var heights = TranscriptRowHeights()
        heights.reset(width: 1440, scale: 1, leading: 1.7)
        let keys = (0..<12).map { index in TranscriptContentKey { $0.combine(index) } }
        for key in keys { heights.note(640, for: key, measuredAt: 1440) }
        let changed = heights.reflow(to: measures)
        #expect(changed)
        #expect(keys.allSatisfy { heights.height(for: $0) == 640 && heights.isStale($0) })
        #expect(heights.staleCount == 12)
        let reset = heights.reset(width: 1440, scale: 1, leading: 1.7, chatMeasures: measures)
        #expect(!reset)
        #expect(heights.count == 12)
        heights.note(420, for: keys[4], measuredAt: 1440)
        #expect(heights.height(for: keys[4]) == 420)
        #expect(!heights.isStale(keys[4]))
        #expect(heights.isStale(keys[3]))
        let unchanged = heights.reflow(to: measures)
        #expect(!unchanged)
        #expect(!heights.isStale(keys[4]))
    }

    @Test("Width preferences default safely and persist independently of themes")
    @MainActor func persistence() throws {
        let domain = "ChatWidthTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("unknown-future-mode", forKey: ChatWidth.defaultsKey)
        let preference = ChatWidthPreference(defaults: defaults)
        #expect(preference.choice == .comfortable)
        #expect(preference.limitsProse)
        preference.choice = .full
        preference.limitsProse = false
        let restored = ChatWidthPreference(defaults: defaults)
        #expect(restored.choice == .full)
        #expect(!restored.limitsProse)
    }

    @Test("Wide content in nested markdown can use the live column")
    func nestedContent() {
        let prose = MarkdownParser.parse("A paragraph with `inline code`.")
        let code = MarkdownParser.parse("- Example:\n\n  ```swift\n  print(1)\n  ```")
        #expect(!prose.contains { $0.needsFullChatColumn })
        #expect(code.contains { $0.needsFullChatColumn })
    }
}
