import SwiftUI
import BloomClient

/// Settled fences keep their syntax work; streamed prefixes occupy only one replaceable entry.
@MainActor
enum BloomCodeRendering {
    final class Prepared {
        let text: AttributedString
        let lineCount: Int
        init(text: AttributedString, lineCount: Int) {
            self.text = text
            self.lineCount = lineCount
        }
    }

    private static let settled: NSCache<NSString, Prepared> = {
        let cache = NSCache<NSString, Prepared>()
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private static var streamed: (key: String, value: Prepared)?

    static func prepare(code: String, language: Language, expanded: Bool, scheme: ColorScheme, streaming: Bool) -> Prepared {
        let key = "\(language.rawValue):\(expanded):\(scheme == .dark):\(code)"
        if streaming, let streamed, streamed.key == key { return streamed.value }
        if !streaming, let cached = settled.object(forKey: key as NSString) { return cached }
        let lines = code.components(separatedBy: "\n")
        let prepared = Prepared(text: highlight(lines, language: language, expanded: expanded, scheme: scheme), lineCount: lines.count)
        if streaming {
            streamed = (key, prepared)
        } else {
            settled.setObject(prepared, forKey: key as NSString, cost: code.utf8.count)
        }
        return prepared
    }

    private static func highlight(_ lines: [String], language: Language, expanded: Bool, scheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        var carry = LexState()
        for (index, line) in lines.prefix(expanded ? lines.count : 2_000).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let value = BloomSyntaxText.line(line, language: language, carry: &carry, scheme: scheme)
            result += value
        }
        return result
    }

}
