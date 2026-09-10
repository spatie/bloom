import Foundation
import Testing
@testable import BloomCore

@Suite("Editor navigation and editing", .scratchDirectory)
struct EditorExperienceTests {
    @Test func locationsPreservePathsAndColumns() {
        #expect(CodeLocation.parse("Sources/My File.swift:42:7") == CodeLocation(path: "Sources/My File.swift", line: 42, column: 7))
        #expect(CodeLocation.parse("foo.php#L19-L23") == CodeLocation(path: "foo.php", line: 19))
        #expect(CodeLocation.parse("file.swift") == CodeLocation(path: "file.swift"))
        #expect(CodeLocation.parse("file.swift:0").line == 1)
    }

    @Test func unicodeAndLineEndings() {
        let text = "a\r\n😀xyz\r\n"
        #expect(CodeLocation.offset(in: text, line: 2, column: 3) == 5)
        #expect(CodeLocation.offset(in: text, line: 2, column: 2) == 3)
        #expect(CodeLocation.offset(in: text, line: 200) == text.utf16.count)
        #expect(CodeLocation.position(in: text, offset: 6).line == 2)
        #expect(CodeLocation.position(in: text, offset: 6).column == 4)
    }

    @Test func historyBranchesAndRestoresPosition() {
        var history = SourceHistory()
        history.visit(CodeLocation(path: "a.swift"))
        history.updateCurrent(CodeLocation(path: "a.swift", line: 30))
        history.visit(CodeLocation(path: "b.swift"))
        let back = history.move(-1)
        #expect(back?.line == 30)
        #expect(history.canGoForward)
        history.visit(CodeLocation(path: "c.swift"))
        #expect(!history.canGoForward)
        #expect(history.entries.map(\.path) == ["a.swift", "c.swift"])
    }

    @Test func indentDoesNotTouchFollowingLine() throws {
        let source = "one\ntwo\nthree"
        let edit = try #require(SourceEditing.lines(in: source, selection: NSRange(location: 0, length: 8), command: .indent, language: .swift))
        #expect(edit.replacement == "    one\n    two\n")
        #expect((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement).hasSuffix("\nthree"))
    }

    @Test func commentsRoundTripAndPreserveCRLF() throws {
        let source = "  let a = 1\r\n  let b = 2\r\n"
        let edit = try #require(SourceEditing.lines(in: source, selection: NSRange(location: 0, length: source.utf16.count), command: .comment, language: .swift))
        #expect(edit.replacement == "  // let a = 1\r\n  // let b = 2\r\n")
        let undo = try #require(SourceEditing.lines(in: edit.replacement, selection: edit.selection, command: .comment, language: .swift))
        #expect(undo.replacement == source)
    }

    @Test func markupCommentRoundTrips() throws {
        let text = "  <div>Hello</div>\n"
        let edit = try #require(SourceEditing.lines(in: text, selection: NSRange(location: 0, length: text.utf16.count), command: .comment, language: .html))
        #expect(edit.replacement == "  <!-- <div>Hello</div> -->\n")
        let undo = try #require(SourceEditing.lines(in: edit.replacement, selection: edit.selection, command: .comment, language: .html))
        #expect(undo.replacement == text)
    }

    @Test func newlineUsesExistingIndentation() {
        let text = "\tif ready {"
        let edit = SourceEditing.newline(in: text, selection: NSRange(location: text.utf16.count, length: 0))
        #expect(edit.replacement == "\n\t\t")
    }

    @Test func bracketsIgnoreCommentsAndStrings() {
        let text = "foo(\" ) \" /* ) */ bar())"
        #expect(SourceEditing.matchingBracket(in: text, at: 3, language: .swift) == text.utf16.count - 1)
        #expect(SourceEditing.matchingBracket(in: text, at: 6, language: .swift) == nil)
    }

    @Test func relativeImportsAndLineLocations() {
        let found = SourceSearch.resolve("../lib/value:12", from: "src/main.ts", root: "/tmp/repo", paths: ["lib/value.ts"])
        #expect(found == CodeLocation(path: "lib/value.ts", line: 12))
        #expect(SourceSearch.resolve("missing", from: "src/main.ts", root: "/tmp/repo", paths: []) == nil)
    }

    @Test func searchSkipsBinaryAndEscapingSymlinks() throws {
        let root = TestScratch.path("repo")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "hello\nneedle here\n".write(toFile: root + "/test.swift", atomically: true, encoding: .utf8)
        try Data("needle\0binary".utf8).write(to: URL(fileURLWithPath: root + "/binary"))
        let outside = TestScratch.path("outside")
        try "needle".write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside)
        let found = try SourceSearch.search(root: root, paths: ["binary", "link", "test.swift"], query: "NEEDLE")
        #expect(found.count == 1)
        #expect(found.first?.location == CodeLocation(path: "test.swift", line: 2))
    }

    @Test func symbolsIgnoreQuotedDeclarations() {
        let text = "// func nope()\nfunc yes() {}\nlet quote = \"class No\"\n"
        let found = SourceSearch.symbols(in: text, path: "demo.swift")
        #expect(found.map(\.location.line) == [2, 3])
    }

    @Test func sourceLinksStayInternal() throws {
        let url = try #require(SourceReference.url("Sources/My File.swift:42:7"))
        #expect(SourceReference.location(url) == CodeLocation(path: "Sources/My File.swift", line: 42, column: 7))
        #expect(!LinkPolicy.opens(url))
        #expect(SourceReference.url("https://example.com/file.swift") == nil)
        #expect(SourceReference.links(in: "See src/File.swift:42 and other.php#L12").count == 2)
    }

    @Test func embeddedLanguagesCarryAcrossLines() {
        let source = "<script lang=\"ts\">\nconst count = 42;\n</script>\n<div>{{ count + 1 }}</div>"
        let tokens = SyntaxHighlighter.tokenize(source: source, language: .vue)
        #expect(tokens[1].contains { $0.kind == .keyword && $0.range == 0..<5 })
        #expect(tokens[1].contains { $0.kind == .number })
        #expect(tokens[3].contains { $0.kind == .number })
        let blade = SyntaxHighlighter.tokenize(source: "{{ $user->name }}", language: .blade)
        #expect(blade[0].contains { $0.kind == .variable })
    }

    @Test func jsxAttributesAndExpressionsHaveDifferentTokens() {
        let text = "const view = <Button disabled={true} title=\"Go\" />"
        let tokens = SyntaxHighlighter.tokenize(source: text, language: .typescript)[0]
        let ns = text as NSString
        let attributes = tokens.filter { $0.kind == .attribute }.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(attributes.contains("disabled"))
        #expect(attributes.contains("title"))
        #expect(tokens.contains { $0.kind == .constant })
    }

    @Test func framesHandleFragmentedUnicodeAndMultipleMessages() throws {
        let first = Data(#"{"id":1,"result":"café"}"#.utf8)
        let second = Data(#"{"id":2,"result":null}"#.utf8)
        let packet = Data("Content-Length: \(first.count)\r\n\r\n".utf8) + first
            + Data("Content-Length: \(second.count)\r\n\r\n".utf8) + second
        var frames = LanguageServerFrames()
        var messages: [JSONValue] = []
        for byte in packet {
            let read = try frames.append(Data([byte]))
            messages += read
        }
        #expect(messages.count == 2)
        #expect(messages.first?["result"]?.stringValue == "café")
    }

    @Test func malformedFramesFail() {
        var frames = LanguageServerFrames()
        #expect(throws: (any Error).self) {
            _ = try frames.append(Data("Content-Length: -1\r\n\r\n".utf8))
        }
    }

    @Test func draftsKeepTypingDuringSaveAndRefuseAgentOverwrites() throws {
        let path = TestScratch.path("draft.swift")
        try "before".write(toFile: path, atomically: true, encoding: .utf8)
        let baseline = try FileEditor.read(path)
        var draft = SourceDraft(baseline: baseline, text: "saved")
        let saved = try FileEditor.write(draft.text, over: baseline)
        draft.text = "typing continued"
        draft.didSave(saved)
        #expect(draft.text == "typing continued")
        #expect(draft.isDirty)
        try "agent version".write(toFile: path, atomically: true, encoding: .utf8)
        let disk = try FileEditor.read(path)
        let accepted = draft.acceptDisk(disk)
        #expect(!accepted)
        #expect(draft.text == "typing continued")
        draft.text = draft.baseline.text
        let refreshed = draft.acceptDisk(disk)
        #expect(refreshed)
        #expect(draft.text == "agent version")
    }

    @Test func definitionLinksUseSelectionRange() throws {
        let response = try #require(JSONValue.parse(#"[{"targetUri":"file:///tmp/My%20File.swift","targetRange":{"start":{"line":0,"character":0}},"targetSelectionRange":{"start":{"line":10,"character":5}}}]"#))
        #expect(SourceLanguageServer.locations(response) == [CodeLocation(path: "/tmp/My File.swift", line: 11, column: 6)])
    }
}
