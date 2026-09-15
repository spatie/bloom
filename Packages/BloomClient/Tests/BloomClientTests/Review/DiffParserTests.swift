import Foundation
import Testing
@testable import BloomClient

struct DiffParserTests {
    @Test("returns nothing for empty and whitespace only input")
    func emptyInput() {
        #expect(DiffParser.parse("").isEmpty)
        #expect(DiffParser.parse("   \n\n\t\n").isEmpty)
        #expect(DiffParser.stats("") == (0, 0))
        #expect(DiffParser.stats("   \n\n") == (0, 0))
    }

    @Test("invents no changed lines out of garbage, and does not hang on it")
    func garbageInput() {
        let garbage = """
        @@@@@@
        @@ - + @@
        @@ -abc,def +ghi @@
        diff --git
        --- \u{0}
        +++
        \\ dangling
        +++++
        """
        // `count >= 0` used to stand here, which is true of every array ever made. `--- \0` is a
        // legal enough header that a file entry for it is fair, but nothing in this input
        // describes a single changed line, so no hunk and no count may be invented from it.
        let files = DiffParser.parse(garbage)
        #expect(files.allSatisfy { $0.hunks.isEmpty })
        #expect(files.allSatisfy { $0.additions == 0 && $0.deletions == 0 })
        #expect(DiffParser.stats(garbage) == (0, 0))
    }

    @Test("reads the single line @@ -1 +1 @@ form")
    func singleLineHunkHeader() {
        let patch = """
        diff --git a/x.txt b/x.txt
        index 1111111..2222222 100644
        --- a/x.txt
        +++ b/x.txt
        @@ -1 +1 @@ inside foo()
        -old
        +new

        """
        let files = DiffParser.parse(patch)
        let hunk = files[0].hunks[0]
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 1)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 1)
        #expect(hunk.header == " inside foo()")
        #expect(hunk.lines.count == 2)
        #expect(hunk.lines[0].oldNumber == 1)
        #expect(hunk.lines[1].newNumber == 1)
    }

    @Test("pairs three deletions with two additions")
    func sideBySidePairing() {
        let patch = """
        diff --git a/p.txt b/p.txt
        --- a/p.txt
        +++ b/p.txt
        @@ -1,5 +1,4 @@
         head
        -one
        -two
        -three
        +uno
        +dos
         tail

        """
        let file = DiffParser.parse(patch)[0]
        let rows = file.sideBySide()

        #expect(rows.count == 5)
        #expect(rows[0].left?.text == "head")
        #expect(rows[0].right?.text == "head")

        #expect(rows[1].left?.text == "one")
        #expect(rows[1].right?.text == "uno")
        #expect(rows[1].isPaired)

        #expect(rows[2].left?.text == "two")
        #expect(rows[2].right?.text == "dos")

        #expect(rows[3].left?.text == "three")
        #expect(rows[3].right == nil)
        #expect(rows[3].isPaired == false)

        #expect(rows[4].left?.text == "tail")
        #expect(rows[4].right?.text == "tail")
        #expect(rows.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test("pads the left column when additions outnumber deletions")
    func sideBySidePadsLeft() {
        let patch = """
        diff --git a/p.txt b/p.txt
        --- a/p.txt
        +++ b/p.txt
        @@ -1,1 +1,3 @@
        -one
        +uno
        +dos
        +tres

        """
        let rows = DiffParser.parse(patch)[0].sideBySide()
        #expect(rows.count == 3)
        #expect(rows[0].left?.text == "one")
        #expect(rows[1].left == nil)
        #expect(rows[2].left == nil)
        #expect(rows.compactMap { $0.right?.text } == ["uno", "dos", "tres"])
    }

    @Test("highlights only the changed word")
    func intraLineSingleWord() {
        let before = "        let value = compute(alpha, beta)"
        let after = "        let value = compute(gamma, beta)"
        let (left, right) = DiffParser.intraLineDiff(before, after)

        #expect(left.count == 1)
        #expect(right.count == 1)
        #expect(String(before[left[0]]) == "alpha")
        #expect(String(after[right[0]]) == "gamma")
    }

    @Test("highlights an inserted word run")
    func intraLineInsertion() {
        let before = "public func run() {"
        let after = "public static func run() {"
        let (left, right) = DiffParser.intraLineDiff(before, after)

        #expect(left.isEmpty)
        #expect(right.count == 1)
        #expect(String(after[right[0]]).contains("static"))
    }

    @Test("reports nothing for identical lines")
    func intraLineIdentical() {
        let (left, right) = DiffParser.intraLineDiff("same", "same")
        #expect(left.isEmpty)
        #expect(right.isEmpty)
    }

    @Test("handles an empty side")
    func intraLineEmptySide() {
        let (left, right) = DiffParser.intraLineDiff("", "added")
        #expect(left.isEmpty)
        #expect(right.count == 1)

        let (left2, right2) = DiffParser.intraLineDiff("removed", "")
        #expect(left2.count == 1)
        #expect(right2.isEmpty)
    }

    @Test("falls back to whole line highlighting past the length limit")
    func intraLineBailsOut() {
        let before = String(repeating: "a", count: 2400) + "X"
        let after = String(repeating: "a", count: 2400) + "Y"
        let (left, right) = DiffParser.intraLineDiff(before, after)

        #expect(left == [before.startIndex..<before.endIndex])
        #expect(right == [after.startIndex..<after.endIndex])
    }

    @Test("parses a very large patch quickly")
    func largePatch() {
        var patch = "diff --git a/huge.txt b/huge.txt\n"
        patch += "index 1111111..2222222 100644\n--- a/huge.txt\n+++ b/huge.txt\n"
        patch += "@@ -1,20000 +1,20000 @@\n"
        var body = ""
        body.reserveCapacity(20_000 * 24)
        for index in 1...10_000 {
            body += "-old line \(index)\n"
            body += "+new line \(index)\n"
        }
        patch += body

        let started = Date()
        let files = DiffParser.parse(patch)
        let elapsed = Date().timeIntervalSince(started)

        #expect(files.count == 1)
        #expect(files[0].additions == 10_000)
        #expect(files[0].deletions == 10_000)
        #expect(files[0].hunks[0].lines.count == 20_000)
        #expect(files[0].hunks[0].lines.last?.newNumber == 10_000)
        #expect(elapsed < 3.0, "parsing 20k lines took \(elapsed)s")

        let rows = files[0].sideBySide()
        #expect(rows.count == 10_000)
        #expect(DiffParser.stats(patch) == (10_000, 10_000))
    }
}
