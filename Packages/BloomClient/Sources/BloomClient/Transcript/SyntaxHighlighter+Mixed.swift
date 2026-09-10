import Foundation

extension SyntaxHighlighter {
    /// Embedded regions keep their own language across lines, including script/style blocks in Vue.
    static func mixedTokens(line: String, language: Language, carry: inout LexState) -> [Token] {
        let ns = line as NSString
        var cursor = 0
        var result: [Token] = []
        let pattern = language == .blade
            ? #"\{\{--(?:.*?--\}\}|.*$)|<script\b[^>]*>|<style\b[^>]*>|\{!!|\{\{|@php\b|<\?php"#
            : #"<script\b[^>]*>|<style\b[^>]*>|\{\{"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        func append(_ tokens: [Token], offset: Int, into result: inout [Token]) {
            result += tokens.map { Token(kind: $0.kind, range: ($0.range.lowerBound + offset)..<($0.range.upperBound + offset)) }
        }
        while cursor < ns.length {
            if let embedded = carry.embeddedLanguage, let end = carry.embeddedEnd {
                let close = ns.range(of: end, options: .caseInsensitive,
                                     range: NSRange(location: cursor, length: ns.length - cursor))
                let stop = close.location == NSNotFound ? ns.length : close.location
                let body = ns.substring(with: NSRange(location: cursor, length: stop - cursor))
                append(lexicalTokens(line: body, language: embedded, carry: &carry), offset: cursor, into: &result)
                cursor = stop
                if close.location != NSNotFound {
                    carry = LexState()
                    append(lexicalTokens(line: ns.substring(with: close), language: language, carry: &carry),
                           offset: cursor, into: &result)
                    cursor += close.length
                }
            } else {
                let next = regex?.firstMatch(in: line, range: NSRange(location: cursor, length: ns.length - cursor))
                let stop = next?.range.location ?? ns.length
                let body = ns.substring(with: NSRange(location: cursor, length: stop - cursor))
                append(lexicalTokens(line: body, language: language, carry: &carry), offset: cursor, into: &result)
                cursor = stop
                guard let next else { break }
                let opener = ns.substring(with: next.range)
                // An apparent opener inside a markup comment remains a comment.
                let probe = lexicalTokens(line: opener, language: language, carry: &carry)
                append(probe, offset: cursor, into: &result)
                cursor += next.range.length
                if probe.allSatisfy({ $0.kind == .comment }) { continue }
                let lower = opener.lowercased()
                if lower.hasPrefix("<script") {
                    carry.embeddedLanguage = lower.contains("ts") || lower.contains("typescript") ? .typescript : .javascript
                    carry.embeddedEnd = "</script>"
                } else if lower.hasPrefix("<style") {
                    carry.embeddedLanguage = .css
                    carry.embeddedEnd = "</style>"
                } else {
                    carry.embeddedLanguage = language == .blade ? .php : .javascript
                    switch lower {
                    case "{!!": carry.embeddedEnd = "!!}"
                    case "@php": carry.embeddedEnd = "@endphp"
                    case "<?php": carry.embeddedEnd = "?>"
                    default: carry.embeddedEnd = "}}"
                    }
                }
            }
        }
        var merged: [Token] = []
        for token in result {
            if let last = merged.last, last.kind == token.kind, token.kind != .plain,
               last.range.upperBound == token.range.lowerBound {
                merged[merged.count - 1].range = last.range.lowerBound..<token.range.upperBound
            } else { merged.append(token) }
        }
        return merged
    }
}
