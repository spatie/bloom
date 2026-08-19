import Testing
@testable import BloomCore

@Suite("Markdown parsing")
struct MarkdownParserTests {
    // MARK: Blocks

    @Test("a plain line is one paragraph")
    func paragraph() {
        #expect(MarkdownParser.parse("hello there") == [.paragraph(inline: [.text("hello there")])])
    }

    @Test("consecutive lines join into one paragraph with a space between them")
    func paragraphJoinsLines() {
        #expect(MarkdownParser.parse("one\ntwo") == [.paragraph(inline: [.text("one two")])])
    }

    @Test("a blank line separates two paragraphs")
    func blankLineSplitsParagraphs() {
        #expect(MarkdownParser.parse("one\n\ntwo") == [
            .paragraph(inline: [.text("one")]),
            .paragraph(inline: [.text("two")]),
        ])
    }

    @Test("carriage returns are normalised before anything else looks at the text")
    func carriageReturns() {
        #expect(MarkdownParser.parse("one\r\n\r\ntwo") == MarkdownParser.parse("one\n\ntwo"))
        #expect(MarkdownParser.parse("one\rtwo") == MarkdownParser.parse("one\ntwo"))
    }

    @Test("an ATX heading carries its level", arguments: [1, 2, 3, 4, 5, 6])
    func atxHeading(level: Int) {
        let hashes = String(repeating: "#", count: level)
        #expect(MarkdownParser.parse("\(hashes) Title") == [.heading(level: level, inline: [.text("Title")])])
    }

    @Test("seven hashes is not a heading")
    func atxTooDeep() {
        #expect(MarkdownParser.parse("####### Title") == [.paragraph(inline: [.text("####### Title")])])
    }

    @Test("a hash with no space after it is not a heading")
    func atxNeedsSpace() {
        #expect(MarkdownParser.parse("#Title") == [.paragraph(inline: [.text("#Title")])])
    }

    @Test("a closing run of hashes is trimmed off a heading")
    func atxClosingHashes() {
        #expect(MarkdownParser.parse("## Title ##") == [.heading(level: 2, inline: [.text("Title")])])
    }

    @Test("underlined text is a setext heading")
    func setext() {
        #expect(MarkdownParser.parse("Title\n=====") == [.heading(level: 1, inline: [.text("Title")])])
        #expect(MarkdownParser.parse("Title\n-----") == [.heading(level: 2, inline: [.text("Title")])])
    }

    @Test("three or more of the same mark on their own is a rule")
    func thematicBreak() {
        #expect(MarkdownParser.parse("---") == [.thematicBreak])
        #expect(MarkdownParser.parse("***") == [.thematicBreak])
        #expect(MarkdownParser.parse("___") == [.thematicBreak])
        #expect(MarkdownParser.parse("- - -") == [.thematicBreak])
    }

    @Test("two marks is not a rule")
    func thematicBreakNeedsThree() {
        #expect(MarkdownParser.parse("**") == [.paragraph(inline: [.text("**")])])
    }

    @Test("a fenced block keeps its code verbatim and detects its language")
    func fencedCode() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n```")
        #expect(blocks == [.codeBlock(code: "let x = 1", language: .swift, info: "swift")])
    }

    @Test("a fence closes only on a longer or equal run of the same character")
    func fenceLength() {
        let blocks = MarkdownParser.parse("````\n```\nstill code\n````")
        #expect(blocks == [.codeBlock(code: "```\nstill code", language: .plainText, info: "")])
    }

    @Test("a tilde fence is not closed by a backtick fence")
    func fenceCharacter() {
        let blocks = MarkdownParser.parse("~~~\n```\n~~~")
        #expect(blocks == [.codeBlock(code: "```", language: .plainText, info: "")])
    }

    @Test("an unterminated fence still yields the code it has, which is what streaming output looks like")
    func unterminatedFence() {
        #expect(MarkdownParser.parse("```swift\nlet x = 1") == [
            .codeBlock(code: "let x = 1", language: .swift, info: "swift"),
        ])
    }

    @Test("a four space indent is a code block")
    func indentedCode() {
        #expect(MarkdownParser.parse("    let x = 1") == [
            .codeBlock(code: "let x = 1", language: .plainText, info: ""),
        ])
    }

    @Test("a quote nests whatever is inside it")
    func blockQuote() {
        #expect(MarkdownParser.parse("> quoted") == [.blockQuote(blocks: [.paragraph(inline: [.text("quoted")])])])
        #expect(MarkdownParser.parse("> # heading") == [.blockQuote(blocks: [.heading(level: 1, inline: [.text("heading")])])])
    }

    // MARK: Lists

    @Test("a run of dashes is one tight bullet list")
    func bulletList() {
        #expect(MarkdownParser.parse("- one\n- two") == [
            .bulletList(items: [
                [.paragraph(inline: [.text("one")])],
                [.paragraph(inline: [.text("two")])],
            ], tight: true),
        ])
    }

    @Test("a blank line between two items spreads the list out")
    func looseList() {
        guard case let .bulletList(_, tight)? = MarkdownParser.parse("- one\n\n- two").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(tight == false)
    }

    @Test("the blank line that merely ends a list does not make it loose")
    func trailingBlankKeepsListTight() {
        guard case let .bulletList(_, tight)? = MarkdownParser.parse("- one\n- two\n\nafter").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(tight == true)
    }

    @Test("a numbered list remembers where it started")
    func numberedListStart() {
        guard case let .numberedList(start, items, _)? = MarkdownParser.parse("3. three\n4. four").first else {
            Issue.record("expected a numbered list")
            return
        }
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test("a bullet needs a space after its marker")
    func bulletNeedsSpace() {
        #expect(MarkdownParser.parse("-not a list") == [.paragraph(inline: [.text("-not a list")])])
    }

    @Test("checkboxes turn a bullet list into a task list")
    func taskList() {
        guard case let .taskList(items)? = MarkdownParser.parse("- [ ] open\n- [x] done").first else {
            Issue.record("expected a task list")
            return
        }
        #expect(items.map(\.checked) == [false, true])
        #expect(items.map(\.inline) == [[.text("open")], [.text("done")]])
    }

    @Test("one unchecked item among plain bullets leaves it a bullet list")
    func mixedTaskList() {
        guard case .bulletList? = MarkdownParser.parse("- [ ] open\n- plain").first else {
            Issue.record("expected a bullet list")
            return
        }
    }

    @Test("an indented line continues the item above it")
    func listContinuation() {
        guard case let .bulletList(items, _)? = MarkdownParser.parse("- one\n  more\n- two").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.first == [.paragraph(inline: [.text("one more")])])
    }

    // MARK: Tables

    @Test("a header, a separator and a row make a table")
    func table() {
        let blocks = MarkdownParser.parse("| a | b |\n| --- | --- |\n| 1 | 2 |")
        #expect(blocks == [
            .table(
                headers: [[.text("a")], [.text("b")]],
                rows: [[[.text("1")], [.text("2")]]],
                alignments: [.leading, .leading]
            ),
        ])
    }

    @Test("colons in the separator set the alignment")
    func tableAlignment() {
        guard case let .table(_, _, alignments)? = MarkdownParser.parse("| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |").first else {
            Issue.record("expected a table")
            return
        }
        #expect(alignments == [.leading, .center, .trailing])
    }

    @Test("a short row is padded out to the width the header declared")
    func tableShortRow() {
        guard case let .table(_, rows, _)? = MarkdownParser.parse("| a | b |\n| --- | --- |\n| 1 |").first else {
            Issue.record("expected a table")
            return
        }
        #expect(rows == [[[.text("1")], []]])
    }

    @Test("a header whose width does not match the separator is not a table")
    func tableWidthMismatch() {
        guard case .paragraph? = MarkdownParser.parse("| a | b |\n| --- |\n| 1 | 2 |").first else {
            Issue.record("expected a paragraph")
            return
        }
    }

    // MARK: Inline

    @Test("stars and underscores mark emphasis")
    func emphasis() {
        #expect(MarkdownParser.parse("*it*") == [.paragraph(inline: [.emphasis([.text("it")])])])
        #expect(MarkdownParser.parse("**it**") == [.paragraph(inline: [.strong([.text("it")])])])
        #expect(MarkdownParser.parse("__it__") == [.paragraph(inline: [.strong([.text("it")])])])
        #expect(MarkdownParser.parse("~~it~~") == [.paragraph(inline: [.strikethrough([.text("it")])])])
    }

    @Test("strong wins over emphasis when both could match")
    func strongBeatsEmphasis() {
        #expect(MarkdownParser.parse("**bold**") == [.paragraph(inline: [.strong([.text("bold")])])])
    }

    @Test("backticks make code, and one space of padding is dropped")
    func inlineCode() {
        #expect(MarkdownParser.parse("`x`") == [.paragraph(inline: [.code("x")])])
        #expect(MarkdownParser.parse("`` ` ``") == [.paragraph(inline: [.code("`")])])
    }

    @Test("code is not looked inside for emphasis")
    func codeIsOpaque() {
        #expect(MarkdownParser.parse("`a_b_c`") == [.paragraph(inline: [.code("a_b_c")])])
    }

    @Test("a bracket and a parenthesis make a link")
    func link() {
        #expect(MarkdownParser.parse("[text](https://example.com)") == [
            .paragraph(inline: [.link(text: [.text("text")], url: "https://example.com")]),
        ])
    }

    @Test("a link with an empty target stays as text")
    func emptyLink() {
        #expect(MarkdownParser.parse("[text]()") == [.paragraph(inline: [.text("[text]()")])])
    }

    @Test("a bare address becomes a link")
    func bareURL() {
        #expect(MarkdownParser.parse("see https://example.com now") == [
            .paragraph(inline: [
                .text("see "),
                .link(text: [.text("https://example.com")], url: "https://example.com"),
                .text(" now"),
            ]),
        ])
    }

    @Test("a full stop after a bare address belongs to the sentence, not the address")
    func bareURLTrailingPunctuation() {
        #expect(MarkdownParser.parse("go to https://example.com.") == [
            .paragraph(inline: [
                .text("go to "),
                .link(text: [.text("https://example.com")], url: "https://example.com"),
                .text("."),
            ]),
        ])
    }

    @Test("an angle bracketed address becomes a link")
    func autolink() {
        #expect(MarkdownParser.parse("<https://example.com>") == [
            .paragraph(inline: [.link(text: [.text("https://example.com")], url: "https://example.com")]),
        ])
    }

    @Test("a backslash escapes the mark that follows it")
    func escape() {
        #expect(MarkdownParser.parse("\\*not emphasis\\*") == [.paragraph(inline: [.text("*not emphasis*")])])
    }

    @Test("two trailing spaces are a hard break")
    func hardBreak() {
        #expect(MarkdownParser.parse("one  \ntwo") == [
            .paragraph(inline: [.text("one"), .lineBreak, .text("two")]),
        ])
    }

    @Test("a trailing backslash is a hard break")
    func backslashHardBreak() {
        #expect(MarkdownParser.parse("one\\\ntwo") == [
            .paragraph(inline: [.text("one"), .lineBreak, .text("two")]),
        ])
    }

    @Test("adjacent text runs are merged so the renderer lays out one string")
    func coalescing() {
        guard case let .paragraph(inline)? = MarkdownParser.parse("a b c d").first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(inline == [.text("a b c d")])
    }

    // MARK: Robustness

    @Test("empty input parses to nothing")
    func empty() {
        #expect(MarkdownParser.parse("") == [])
        #expect(MarkdownParser.parse("\n\n\n") == [])
    }

    @Test("unbalanced marks never hang the parser", arguments: [
        "*", "**", "***", "`", "``", "[", "[]", "[](", "<", "~~", "|", "|-", "> ", "- ", "1. ",
        "***a**", "[a](b", "`a", "**a*", "___", "____", "- [ ", "|a|\n|-",
    ])
    func fragmentsTerminate(fragment: String) {
        _ = MarkdownParser.parse(fragment)
    }

    @Test("every prefix of a document parses, which is what a stream hands us")
    func everyPrefixParses() {
        let document = """
        # Title

        Some **bold** and `code` and a [link](https://example.com).

        - one
        - [x] two

        | a | b |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        > quoted
        """
        for length in 0...document.count {
            _ = MarkdownParser.parse(String(document.prefix(length)))
        }
    }
}
