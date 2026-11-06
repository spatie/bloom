import Testing
@testable import BloomCore

@Suite("Long answers cut into parts")
struct TranscriptAnswerPartsTests {
    /// One section of the kind an agent writes: every block type the parser knows, a fence with
    /// blank lines and a heading-looking line inside it, and a loose list.
    private func section(_ number: Int) -> String {
        """
        ## Section \(number)

        A paragraph about step \(number) that is long enough to wrap over a couple of lines in \
        the transcript, with `inline code` and a [link](https://example.com/\(number)).

        - **first**: one item
        - **second**: another item

        | name | value | note |
        |---|:---:|---:|
        | alpha | \(number) | left |
        | beta | \(number + 1) | right |

        ```swift
        let value = \(number)

        # not a heading, still code
        print(value)
        ```

        > A quote that says something about section \(number).

        1. First step

        2. Second step, loose
        """
    }

    private func answer(sections: Int) -> String {
        (1...sections).map(section).joined(separator: "\n\n")
    }

    @Test("a short answer is one part, the text itself")
    func shortAnswer() {
        let text = answer(sections: 2)
        #expect(text.utf8.count <= TranscriptAnswerParts.threshold)
        #expect(TranscriptAnswerParts.split(text) == [text])
    }

    @Test("the parts of a long answer parse to the blocks of the whole")
    func partsParseLikeTheWhole() {
        let text = answer(sections: 30)
        let parts = TranscriptAnswerParts.split(text)
        #expect(parts.count > 1)
        #expect(parts.flatMap(MarkdownParser.parse) == MarkdownParser.parse(text))
    }

    @Test("a part opening on indented code keeps it code")
    func indentedCode() {
        let paragraph = "A paragraph long enough to carry its share of the answer. " + String(repeating: "word ", count: 120)
        let code = (1...30).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let text = (1...8).map { _ in paragraph + "\n\n" + code }.joined(separator: "\n\n")
        let parts = TranscriptAnswerParts.split(text)
        #expect(parts.contains { $0.hasPrefix("    let value1 ") })
        #expect(parts.flatMap(MarkdownParser.parse) == MarkdownParser.parse(text))
    }

    @Test("carriage returns cut the same way")
    func carriageReturns() {
        let text = answer(sections: 12)
        let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(TranscriptAnswerParts.split(crlf) == TranscriptAnswerParts.split(text))
    }

    @Test("a fence is never cut, however long")
    func longFence() {
        let code = (1...600).map { "let line\($0) = \($0)\n" }.joined()
        let text = answer(sections: 4) + "\n\n```swift\n\(code)\n```\n\n" + answer(sections: 4)
        let parts = TranscriptAnswerParts.split(text)
        #expect(parts.count > 2)
        #expect(parts.flatMap(MarkdownParser.parse) == MarkdownParser.parse(text))
        for part in parts {
            let fences = part.split(separator: "\n").filter { $0.hasPrefix("```") }
            #expect(fences.count.isMultiple(of: 2))
        }
    }

    @Test("a part closes once it reaches the target, and a short remainder stays with the last")
    func cuts() {
        let target = TranscriptAnswerParts.target
        #expect(TranscriptAnswerParts.cuts(sizes: [1_000, 1_000, 1_000, 100]) == [0, 2])
        #expect(TranscriptAnswerParts.cuts(sizes: [target + 500, 300]) == [0])
        #expect(TranscriptAnswerParts.cuts(sizes: [target, target, target]) == [0, 1, 2])
        #expect(TranscriptAnswerParts.cuts(sizes: []) == [])
    }
}
