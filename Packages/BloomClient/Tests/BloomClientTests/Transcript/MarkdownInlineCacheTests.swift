import Testing
@testable import BloomClient

@Suite("Streaming inline parse cache")
struct MarkdownInlineCacheTests {
    @Test("Unicode code examples retain their exact source bytes")
    func unicodeSource() {
        let cache = MarkdownInlineCache()
        for source in ["é", "e\u{0301}", "é"] {
            let value = cache.value(for: source) { [.code(source)] }
            guard case .code(let code) = value.first else { Issue.record("missing code"); return }
            #expect(Array(code.utf8) == Array(source.utf8))
        }
    }

    @Test("exact source is reused but different whitespace and markup are not")
    func exactSource() {
        let cache = MarkdownInlineCache()
        var builds = 0
        for source in ["hello", "hello", "hello ", "**hello**", "hello"] {
            let value = cache.value(for: source) { builds += 1; return [.text(source)] }
            #expect(value == [.text(source)])
        }
        #expect(builds == 3)
    }

    @Test("entry and source-byte budgets evict old prefixes", arguments: [true, false])
    func bounded(byCount: Bool) {
        let cache = MarkdownInlineCache(maximumEntries: byCount ? 2 : 10, maximumBytes: byCount ? 100 : 4)
        var builds = 0
        for source in ["aa", "bb", "cc", "aa"] {
            _ = cache.value(for: source) { builds += 1; return [.text(source)] }
        }
        #expect(builds == 4)
    }

    @Test("oversized lines are not retained")
    func oversized() {
        let cache = MarkdownInlineCache(maximumBytes: 2)
        var builds = 0
        for _ in 0..<2 {
            _ = cache.value(for: "large") { builds += 1; return [.text("large")] }
        }
        #expect(builds == 2)
    }

    @Test("nested parsing does not hold the cache lock")
    func recursive() {
        let cache = MarkdownInlineCache()
        let value = cache.value(for: "**word**") {
            [.strong(cache.value(for: "word") { [.text("word")] })]
        }
        #expect(value == [.strong([.text("word")])])
    }

    @Test("concurrent readers cannot mix source values")
    func concurrent() async {
        let cache = MarkdownInlineCache(maximumEntries: 4)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let source = "line \(index % 9)"
                    let value = cache.value(for: source) { [.text(source)] }
                    #expect(value == [.text(source)])
                }
            }
        }
    }

    @Test("cached text keeps soft and hard line breaks distinct")
    func lineBreakContext() {
        for _ in 0..<3 {
            #expect(MarkdownParser.parse("one\ntwo") == [.paragraph(inline: [.text("one two")])])
            #expect(MarkdownParser.parse("one  \ntwo") == [
                .paragraph(inline: [.text("one"), .lineBreak, .text("two")]),
            ])
        }
    }
}
