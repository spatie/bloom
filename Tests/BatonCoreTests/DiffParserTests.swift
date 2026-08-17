import Testing
import Foundation
@testable import BatonCore

// MARK: - Git fixture helper

/// A throwaway repository, so the fixtures under test are whatever the installed git actually
/// prints rather than what we remember it printing.
private struct GitFixture {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "baton-diff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git("init", "-q", ".")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
        try git("config", "core.autocrlf", "false")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try run(arguments)
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path + "/" + name))
    }

    func write(_ name: String, bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path + "/" + name))
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// The working tree patch, which is exactly what Git.patch feeds the parser.
    func diff(_ extra: String...) throws -> String {
        try run(["diff", "--no-color", "-M"] + extra)
    }
}

private func numbered(_ prefix: String, _ range: ClosedRange<Int>) -> String {
    range.map { "\(prefix)\($0)\n" }.joined()
}

@Suite("DiffParser")
struct DiffParserTests {

    // MARK: Real git fixtures

    @Test("parses a one hunk modification with numbers on both sides")
    func simpleModification() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("a.txt", numbered("line", 1...10))
        try fixture.commit("init")
        try fixture.write("a.txt", "line1\nline2\nCHANGED\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n")

        let patch = try fixture.diff()
        let files = DiffParser.parse(patch)

        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.oldPath == "a.txt")
        #expect(file.newPath == "a.txt")
        #expect(file.additions == 1)
        #expect(file.deletions == 1)
        #expect(file.isBinary == false)
        #expect(file.isRename == false)

        let hunk = try #require(file.hunks.first)
        #expect(file.hunks.count == 1)
        #expect(hunk.oldStart == 1)
        #expect(hunk.newStart == 1)

        let deletion = try #require(hunk.lines.first { $0.kind == .deletion })
        #expect(deletion.text == "line3")
        #expect(deletion.oldNumber == 3)
        #expect(deletion.newNumber == nil)

        let addition = try #require(hunk.lines.first { $0.kind == .addition })
        #expect(addition.text == "CHANGED")
        #expect(addition.newNumber == 3)
        #expect(addition.oldNumber == nil)

        // Context after the change keeps stepping on both sides.
        let trailing = hunk.lines.filter { $0.kind == .context && $0.text == "line4" }
        #expect(trailing.first?.oldNumber == 4)
        #expect(trailing.first?.newNumber == 4)

        #expect(DiffParser.stats(patch) == (1, 1))
    }

    @Test("keeps numbering across multiple hunks in one file")
    func multipleHunks() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("big.txt", numbered("line", 1...60))
        try fixture.commit("init")

        var lines = (1...60).map { "line\($0)" }
        lines[4] = "EARLY"
        lines[49] = "LATE"
        try fixture.write("big.txt", lines.map { $0 + "\n" }.joined())

        let files = DiffParser.parse(try fixture.diff())
        let file = try #require(files.first)
        #expect(file.hunks.count == 2)
        #expect(file.additions == 2)
        #expect(file.deletions == 2)

        let first = file.hunks[0]
        let second = file.hunks[1]
        #expect(second.oldStart > first.oldStart + first.oldCount)

        let early = try #require(first.lines.first { $0.kind == .deletion })
        #expect(early.text == "line5")
        #expect(early.oldNumber == 5)

        let late = try #require(second.lines.first { $0.kind == .deletion })
        #expect(late.text == "line50")
        #expect(late.oldNumber == 50)
        #expect(second.lines.first { $0.kind == .addition }?.newNumber == 50)

        // Every context line in the second hunk lines up with its own numbering.
        for line in second.lines where line.kind == .context {
            #expect(line.oldNumber == line.newNumber)
        }
    }

    @Test("splits a patch touching several files")
    func multiFilePatch() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("one.txt", "one\n")
        try fixture.write("two.txt", "two\n")
        try fixture.write("three.txt", "three\n")
        try fixture.commit("init")
        try fixture.write("one.txt", "ONE\n")
        try fixture.write("two.txt", "TWO\n")
        try fixture.write("three.txt", "THREE\n")

        let patch = try fixture.diff()
        let files = DiffParser.parse(patch)

        #expect(files.count == 3)
        #expect(Set(files.map(\.id)) == ["one.txt", "two.txt", "three.txt"])
        #expect(files.allSatisfy { $0.additions == 1 && $0.deletions == 1 })
        #expect(DiffParser.stats(patch) == (3, 3))
    }

    @Test("reads a new file as an addition against /dev/null")
    func newFile() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("keep.txt", "keep\n")
        try fixture.commit("init")
        try fixture.write("fresh.txt", "alpha\nbeta\n")
        try fixture.git("add", "-A")

        let files = DiffParser.parse(try fixture.diff("--cached"))
        let file = try #require(files.first)
        #expect(file.oldPath == nil)
        #expect(file.newPath == "fresh.txt")
        #expect(file.isNew)
        #expect(file.newMode == "100644")
        #expect(file.additions == 2)
        #expect(file.hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(file.hunks[0].lines.allSatisfy { $0.oldNumber == nil })
    }

    @Test("reads a deleted file")
    func deletedFile() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("gone.txt", "a\nb\n")
        try fixture.write("stay.txt", "s\n")
        try fixture.commit("init")
        try FileManager.default.removeItem(atPath: fixture.path + "/gone.txt")

        let files = DiffParser.parse(try fixture.diff())
        let file = try #require(files.first)
        #expect(file.oldPath == "gone.txt")
        #expect(file.newPath == nil)
        #expect(file.isDeleted)
        #expect(file.oldMode == "100644")
        #expect(file.deletions == 2)
        #expect(file.hunks[0].lines.map(\.oldNumber) == [1, 2])
    }

    @Test("reads a rename")
    func rename() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("before.txt", numbered("shared", 1...20))
        try fixture.commit("init")
        try fixture.git("mv", "before.txt", "after.txt")

        let files = DiffParser.parse(try fixture.diff("--cached"))
        let file = try #require(files.first)
        #expect(file.isRename)
        #expect(file.oldPath == "before.txt")
        #expect(file.newPath == "after.txt")
        #expect(file.id == "after.txt")
        #expect(file.hunks.isEmpty)
    }

    @Test("flags a binary file")
    func binaryFile() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("blob.bin", bytes: [0x00, 0x01, 0x02, 0xFF, 0x00, 0x41])
        try fixture.commit("init")
        try fixture.write("blob.bin", bytes: [0x00, 0x09, 0x02, 0xFE, 0x00, 0x42])

        let patch = try fixture.diff()
        #expect(patch.contains("Binary files"))

        let files = DiffParser.parse(patch)
        let file = try #require(files.first)
        #expect(file.isBinary)
        #expect(file.newPath == "blob.bin")
        #expect(file.hunks.isEmpty)
        #expect(file.additions == 0)
        #expect(file.deletions == 0)
    }

    @Test("keeps the no newline marker on both sides")
    func noNewlineMarkers() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("nonl.txt", "a")
        try fixture.commit("init")
        try fixture.write("nonl.txt", "b")

        let patch = try fixture.diff()
        #expect(patch.contains("\\ No newline at end of file"))

        let files = DiffParser.parse(patch)
        let hunk = try #require(files.first?.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.deletion, .noNewline, .addition, .noNewline])
        #expect(hunk.lines[0].text == "a")
        #expect(hunk.lines[1].text == "No newline at end of file")
        #expect(hunk.lines[2].text == "b")
        #expect(hunk.lines[1].oldNumber == nil)
        #expect(hunk.lines[1].newNumber == nil)
        #expect(files[0].additions == 1)
        #expect(files[0].deletions == 1)

        // The marker rides along with the line it annotates instead of splitting the pair.
        let rows = files[0].sideBySide()
        #expect(rows.count == 2)
        #expect(rows[0].left?.text == "a")
        #expect(rows[0].right?.text == "b")
        #expect(rows[1].left?.kind == .noNewline)
        #expect(rows[1].right?.kind == .noNewline)
    }

    @Test("handles a path containing a space")
    func pathWithSpace() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("my notes.txt", "one\n")
        try fixture.commit("init")
        try fixture.write("my notes.txt", "one\ntwo\n")

        let patch = try fixture.diff()
        let files = DiffParser.parse(patch)
        let file = try #require(files.first)
        #expect(file.oldPath == "my notes.txt")
        #expect(file.newPath == "my notes.txt")
        #expect(file.additions == 1)
    }

    @Test("handles git's quoted path form")
    func quotedPath() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("café.txt", "one\n")
        try fixture.commit("init")
        try fixture.write("café.txt", "two\n")

        let patch = try fixture.diff()
        #expect(patch.contains("\\303\\251"))

        let files = DiffParser.parse(patch)
        let file = try #require(files.first)
        #expect(file.newPath == "café.txt")
        #expect(file.oldPath == "café.txt")
    }

    @Test("parses a mode only change")
    func modeOnlyChange() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("script.sh", "echo hi\n")
        try fixture.commit("init")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.path + "/script.sh"
        )

        let files = DiffParser.parse(try fixture.diff())
        let file = try #require(files.first)
        #expect(file.oldMode == "100644")
        #expect(file.newMode == "100755")
        #expect(file.hunks.isEmpty)
        #expect(file.isModeChangeOnly)
        #expect(file.newPath == "script.sh")
    }

    @Test("parses the --no-index form used for untracked files")
    func untrackedNoIndex() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("seed.txt", "seed\n")
        try fixture.commit("init")
        try fixture.write("brand-new.txt", "x\ny\n")

        let patch = try fixture.run(["diff", "--no-index", "--no-color", "/dev/null", "brand-new.txt"])
        let files = DiffParser.parse(patch)
        let file = try #require(files.first)
        #expect(file.oldPath == nil)
        #expect(file.newPath == "brand-new.txt")
        #expect(file.additions == 2)
    }

    // MARK: Hand written edge cases

    @Test("returns nothing for empty and whitespace only input")
    func emptyInput() {
        #expect(DiffParser.parse("").isEmpty)
        #expect(DiffParser.parse("   \n\n\t\n").isEmpty)
        #expect(DiffParser.stats("") == (0, 0))
        #expect(DiffParser.stats("   \n\n") == (0, 0))
    }

    @Test("survives garbage without hanging")
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
        let files = DiffParser.parse(garbage)
        #expect(files.count >= 0)
        _ = DiffParser.stats(garbage)
    }

    @Test("parses a patch truncated mid hunk")
    func truncatedPatch() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("t.txt", numbered("line", 1...20))
        try fixture.commit("init")
        var lines = (1...20).map { "line\($0)" }
        lines[9] = "CHANGED"
        try fixture.write("t.txt", lines.map { $0 + "\n" }.joined())

        let full = try fixture.diff()
        let truncated = full.components(separatedBy: "\n").prefix(7).joined(separator: "\n")

        let files = DiffParser.parse(truncated)
        let file = try #require(files.first)
        #expect(file.newPath == "t.txt")
        let hunk = try #require(file.hunks.first)
        // The header still claims the full hunk even though the body stops early.
        #expect(hunk.oldCount > hunk.lines.count)
        #expect(hunk.lines.allSatisfy { $0.oldNumber != nil || $0.newNumber != nil })
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

    @Test("captures the section heading after the closing @@")
    func hunkHeading() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        let source = """
        func alpha() {
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let e = 5
            let f = 6
            let g = 7
        }

        """
        try fixture.write("Code.swift", source)
        try fixture.commit("init")
        try fixture.write("Code.swift", source.replacingOccurrences(of: "let e = 5", with: "let e = 55"))

        let files = DiffParser.parse(try fixture.diff())
        let hunk = try #require(files.first?.hunks.first)
        #expect(hunk.header.contains("func alpha"))
    }

    // MARK: Side by side

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

    @Test("puts context lines in both columns of a real patch")
    func sideBySideOnRealPatch() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("s.txt", numbered("line", 1...10))
        try fixture.commit("init")
        var lines = (1...10).map { "line\($0)" }
        lines[4] = "FIVE"
        try fixture.write("s.txt", lines.map { $0 + "\n" }.joined())

        let file = DiffParser.parse(try fixture.diff())[0]
        let rows = file.sideBySide()
        #expect(rows.contains { $0.isPaired })
        for row in rows where row.left?.kind == .context {
            #expect(row.left?.text == row.right?.text)
            #expect(row.right?.kind == .context)
        }
    }

    // MARK: Intra-line

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

    @Test("word diffs a line taken from a real patch")
    func intraLineFromGit() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }

        try fixture.write("Code.swift", "let total = subtotal + shipping\n")
        try fixture.commit("init")
        try fixture.write("Code.swift", "let total = subtotal + handling\n")

        let file = DiffParser.parse(try fixture.diff())[0]
        let row = try #require(file.sideBySide().first { $0.isPaired })
        let beforeText = try #require(row.left?.text)
        let afterText = try #require(row.right?.text)

        let (left, right) = DiffParser.intraLineDiff(beforeText, afterText)
        #expect(left.map { String(beforeText[$0]) } == ["shipping"])
        #expect(right.map { String(afterText[$0]) } == ["handling"])
    }

    // MARK: Performance

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
