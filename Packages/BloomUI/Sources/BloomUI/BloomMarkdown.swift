import SwiftUI
import BloomClient

/// Mobile's default adapter uses the same parser, block layout and syntax lexer as the Mac.
public struct BloomMarkdown: View {
    private let text: String
    private let isStreaming: Bool
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var markerWidth = 24.0
    @ScaledMetric(relativeTo: .callout) private var tableColumnWidth = 144.0

    public init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        BloomMarkdownBlocks(blocks: BloomMarkdownCache.blocks(text, streaming: isStreaming), style: style) { text, role, colour, spacing in
            Text(BloomInlineText.render(text, role: role, colour: colour, scheme: scheme))
                .textSelection(.enabled)
                .lineSpacing(spacing ?? 3)
                .fixedSize(horizontal: false, vertical: true)
        } code: { text, language in
            BloomCodeBlock(code: text, language: language, isStreaming: isStreaming)
        }
    }

    private var style: BloomMarkdownStyle {
        var value = BloomMarkdownStyle()
        value.markerWidth = markerWidth
        value.minimumTableColumnWidth = tableColumnWidth
        value.tertiary = BloomColour.resolve(PaletteInk.textTertiary, scheme: scheme)
        value.border = BloomColour.resolve(PaletteInk.border, scheme: scheme)
        value.surface = BloomColour.resolve(PaletteInk.surfaceSunken, scheme: scheme)
        return value
    }
}

@MainActor
private enum BloomMarkdownCache {
    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let settled: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private static var streamed: (text: String, blocks: [MarkdownBlock])?

    static func blocks(_ text: String, streaming: Bool) -> [MarkdownBlock] {
        if streaming {
            if let streamed, streamed.text == text { return streamed.blocks }
            let blocks = MarkdownParser.parse(text)
            streamed = (text, blocks)
            return blocks
        }
        if let cached = settled.object(forKey: text as NSString) { return cached.blocks }
        let blocks = MarkdownParser.parse(text)
        settled.setObject(BlocksBox(blocks), forKey: text as NSString, cost: text.utf8.count)
        return blocks
    }
}
