import Testing
import Foundation
@testable import BloomCore

/// The tail of a running log, which is what the transcript shows of a setup script.
@Suite("Log tail")
struct LogTailTests {
    private let log = "one\ntwo\nthree\nfour\nfive\n"

    @Test("the last lines come back in order")
    func takesTheEnd() {
        #expect(LogTail.last(log, lines: 2) == "four\nfive")
        #expect(LogTail.last(log, lines: 3) == "three\nfour\nfive")
    }

    @Test("asking for more lines than there are gives all of them")
    func takesEverything() {
        #expect(LogTail.last(log, lines: 99) == "one\ntwo\nthree\nfour\nfive")
        #expect(LogTail.last("only one line", lines: 4) == "only one line")
    }

    @Test("a trailing newline does not cost a line")
    func ignoresTrailingNewlines() {
        #expect(LogTail.last("a\nb\n\n\n", lines: 1) == "b")
        #expect(LogTail.last("a\nb", lines: 1) == "b")
    }

    @Test("nothing in, nothing out")
    func handlesEmpty() {
        #expect(LogTail.last("", lines: 3).isEmpty)
        #expect(LogTail.last("\n\n\n", lines: 3).isEmpty)
        #expect(LogTail.last(log, lines: 0).isEmpty)
    }

    @Test("the last line with anything on it")
    func findsTheLastLine() {
        #expect(LogTail.lastLine(log) == "five")
        #expect(LogTail.lastLine("  composer install  \n") == "composer install")
        #expect(LogTail.lastLine("").isEmpty)
    }

    @Test("lines are counted rather than split")
    func counts() {
        #expect(LogTail.lineCount(log) == 5)
        #expect(LogTail.lineCount("one line") == 1)
        #expect(LogTail.lineCount("") == 0)
        #expect(LogTail.lineCount("\n\n") == 0)
        #expect(LogTail.lineCount("a\n\nb\n") == 3)
    }

    @Test("a log of real size is walked from the end rather than copied")
    func handlesALargeLog() {
        let big = (0..<20_000).map { "line \($0)" }.joined(separator: "\n")

        #expect(LogTail.last(big, lines: 2) == "line 19998\nline 19999")
        #expect(LogTail.lastLine(big) == "line 19999")
    }
}
