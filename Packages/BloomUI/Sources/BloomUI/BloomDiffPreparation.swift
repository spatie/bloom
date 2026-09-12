import SwiftUI
import BloomClient

/// Syntax is prepared once per patch. Additions and deletions carry independent lexer states.
@MainActor
enum BloomDiffPreparation {
    final class Prepared {
        let lines: [[AttributedString]]
        let longestLine: Int
        init(lines: [[AttributedString]], longestLine: Int) { self.lines = lines; self.longestLine = longestLine }
    }

    private final class Key: NSObject {
        let file: FileDiff
        let dark: Bool
        init(_ file: FileDiff, dark: Bool) { self.file = file; self.dark = dark }
        override var hash: Int { file.hashValue ^ dark.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return file == other.file && dark == other.dark
        }
    }

    private static let cache: NSCache<Key, Prepared> = {
        let value = NSCache<Key, Prepared>()
        value.totalCostLimit = 8 * 1_024 * 1_024
        return value
    }()

    static func prepare(_ file: FileDiff, scheme: ColorScheme) -> Prepared {
        let key = Key(file, dark: scheme == .dark)
        if let value = cache.object(forKey: key) { return value }
        let language = Language.detect(path: file.displayPath)
        var longest = 0
        var cost = 0
        let lines = file.hunks.map { hunk in
            var old = LexState()
            var new = LexState()
            return hunk.lines.map { line in
                let text = line.text.replacingOccurrences(of: "\t", with: "    ")
                longest = max(longest, text.utf16.count)
                cost += text.utf8.count
                switch line.kind {
                case .addition: return BloomSyntaxText.line(text, language: language, carry: &new, scheme: scheme)
                case .deletion: return BloomSyntaxText.line(text, language: language, carry: &old, scheme: scheme)
                case .context:
                    _ = SyntaxHighlighter.tokenize(line: text, language: language, carry: &old)
                    return BloomSyntaxText.line(text, language: language, carry: &new, scheme: scheme)
                case .noNewline: return AttributedString("No newline at end of file")
                }
            }
        }
        let value = Prepared(lines: lines, longestLine: longest)
        cache.setObject(value, forKey: key, cost: cost)
        return value
    }
}
