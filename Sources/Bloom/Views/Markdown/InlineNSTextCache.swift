import AppKit
import BloomCore

/// Now that unlinked prose also uses AppKit, keep settled runs from rebuilding their attributed
/// strings on every transcript update. Streaming has a smaller, separate cache: completed
/// paragraphs reuse their runs while the final paragraph grows, without evicting settled prose.
@MainActor
enum InlineNSTextCache {
    private final class Key: NSObject {
        let inline: [MarkdownInline]
        let font: NSFont
        let code: NSFont
        let color: NSColor
        let spacing: CGFloat

        init(_ inline: [MarkdownInline], font: NSFont, code: NSFont, color: NSColor, spacing: CGFloat) {
            self.inline = inline
            self.font = font
            self.code = code
            self.color = color
            self.spacing = spacing
        }

        override var hash: Int { inline.count ^ font.hash ^ code.hash ^ color.hash ^ spacing.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return inline == other.inline && font == other.font && code == other.code
                && color == other.color && spacing == other.spacing
        }
    }

    private static let settled: NSCache<Key, NSAttributedString> = {
        let cache = NSCache<Key, NSAttributedString>()
        cache.countLimit = 1_024
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private static let streamed: NSCache<Key, NSAttributedString> = {
        let cache = NSCache<Key, NSAttributedString>()
        cache.countLimit = 128
        cache.totalCostLimit = 1_024 * 1_024
        return cache
    }()

    static func make(
        _ inline: [MarkdownInline], font: NSFont, code: NSFont, color: NSColor,
        lineSpacing: CGFloat, isStreaming: Bool
    ) -> NSAttributedString {
        let key = Key(inline, font: font, code: code, color: color, spacing: lineSpacing)
        let cache = isStreaming ? streamed : settled
        if let value = cache.object(forKey: key) { return value }
        let value = InlineNSAttributes.make(inline, font: font, code: code, color: color, lineSpacing: lineSpacing)
        cache.setObject(value, forKey: key, cost: value.length * 2)
        return value
    }
}
