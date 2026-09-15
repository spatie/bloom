import Foundation
import Testing
@testable import BloomCore

struct SyntaxCacheKeyTests {
    @Test("highlighting keeps canonically equal source text separate", arguments: [false, true])
    func unicodeCacheEntries(reverse: Bool) throws {
        let composed = "// caf\u{e9}"
        let decomposed = "// cafe\u{301}"
        #expect(composed == decomposed)
        #expect(composed.utf16.count != decomposed.utf16.count)

        let cache = NSCache<SyntaxCacheKey, NSAttributedString>()
        let lines = reverse ? [decomposed, composed] : [composed, decomposed]
        for line in lines {
            let key = SyntaxCacheKey(line: line, language: .swift, carry: LexState())
            #expect(cache.object(forKey: key) == nil)
            cache.setObject(NSAttributedString(string: line), forKey: key)
        }

        for line in lines {
            let key = SyntaxCacheKey(line: line, language: .swift, carry: LexState())
            let cached = try #require(cache.object(forKey: key))
            #expect(cached.string.utf8.elementsEqual(line.utf8))
            #expect(cached.length == line.utf16.count)
        }
    }

    @Test("identical source reuses highlighting but language and lexer state stay separate")
    func highlightingContext() {
        let cache = NSCache<SyntaxCacheKey, NSAttributedString>()
        let value = NSAttributedString(string: "return value")
        cache.setObject(value, forKey: SyntaxCacheKey(line: value.string, language: .swift, carry: LexState()))

        let same = SyntaxCacheKey(line: value.string, language: .swift, carry: LexState())
        #expect(cache.object(forKey: same) === value)
        let otherLanguage = SyntaxCacheKey(line: value.string, language: .php, carry: LexState())
        #expect(cache.object(forKey: otherLanguage) == nil)

        var comment = LexState()
        _ = SyntaxHighlighter.tokenize(line: "/*", language: .swift, carry: &comment)
        let otherState = SyntaxCacheKey(line: value.string, language: .swift, carry: comment)
        #expect(cache.object(forKey: otherState) == nil)
    }
}
