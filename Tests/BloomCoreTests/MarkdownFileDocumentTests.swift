import Foundation
import Testing
@testable import BloomCore

@Suite("Markdown file previews", .scratchDirectory)
struct MarkdownFileDocumentTests {
    @Test("unsaved Markdown is previewed without writing it to disk")
    func draftWins() throws {
        let path = TestScratch.path("README.md")
        try "# Saved".write(toFile: path, atomically: true, encoding: .utf8)
        let document = try MarkdownFileDocument.read(path: path, draft: "# Unsaved")
        #expect(document.text == "# Unsaved")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# Saved")
    }

    @Test("without a draft the preview reads the latest file contents")
    func readsDisk() throws {
        let path = TestScratch.path("README.md")
        try "# Latest".write(toFile: path, atomically: true, encoding: .utf8)
        let document = try MarkdownFileDocument.read(path: path, draft: nil)
        #expect(document.text == "# Latest")
        #expect(!document.isTruncated)
    }

    @Test("an empty unsaved document does not fall back to saved text")
    func emptyDraft() throws {
        let document = try MarkdownFileDocument.read(path: TestScratch.path("missing.md"), draft: "")
        #expect(document.text.isEmpty)
    }

    @Test("missing files report an error when there is no draft")
    func missingFile() {
        let path = TestScratch.path("missing.md")
        #expect(throws: FileEditorError.missing(path)) {
            try MarkdownFileDocument.read(path: path, draft: nil)
        }
    }

    @Test("long previews stop at the line limit and say they were truncated")
    func truncation() throws {
        let lines = (0...MarkdownFileDocument.lineLimit).map { "Line \($0)" }
        let document = try MarkdownFileDocument.read(
            path: TestScratch.path("large.md"), draft: lines.joined(separator: "\n")
        )
        #expect(document.isTruncated)
        #expect(document.text.components(separatedBy: "\n").count == MarkdownFileDocument.lineLimit)
        #expect(document.text.hasSuffix("Line \(MarkdownFileDocument.lineLimit - 1)"))
    }
}
