import Testing
import Foundation
@testable import BloomCore

/// The cut that both hover cards make: the head of a file, and the head of a block of instructions
/// that never was one.
///
/// It moved out of the view when the second caller arrived, and these are the three behaviours the
/// first one depended on and nobody had written down: a last line that is only whitespace is not a
/// line, a long line is cut with an ellipsis rather than wrapped, and a tab is four spaces because
/// a tab drawn at its own width makes one line as wide as the screen.
@Suite("Text head")
struct TextHeadTests {
    @Test("nothing to show answers nothing")
    func emptyTextHasNoHead() {
        #expect(TextHead.head(of: "") == nil)
        #expect(TextHead.head(of: "\n\n   \n") == nil)
    }

    @Test("a short text is itself, whole")
    func shortTextIsWhole() throws {
        let head = try #require(TextHead.head(of: "one\ntwo\n"))
        #expect(head.lines == ["one", "two"])
        #expect(!head.truncated)
    }

    @Test("a long text is cut and says so")
    func longTextIsCut() throws {
        let text = (1...40).map(String.init).joined(separator: "\n")
        let head = try #require(TextHead.head(of: text, lines: 3))
        #expect(head.lines == ["1", "2", "3"])
        #expect(head.truncated)
    }

    @Test("a long line is cut with an ellipsis rather than wrapped")
    func longLinesAreCut() throws {
        let head = try #require(TextHead.head(of: String(repeating: "x", count: 20), columns: 8))
        #expect(head.lines == [String(repeating: "x", count: 8) + "\u{2026}"])
        #expect(!head.truncated)
    }

    @Test("a tab is four spaces")
    func tabsAreExpanded() throws {
        let head = try #require(TextHead.head(of: "\tindented"))
        #expect(head.lines == ["    indented"])
    }
}
