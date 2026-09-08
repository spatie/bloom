import Foundation
import Testing
@testable import BloomCore

@Suite("Markdown note formatting")
struct NoteFormattingTests {
    private func apply(_ action: NoteFormatting.Action, to source: String, selection: NSRange) throws -> (String, NSRange) {
        let edit = try #require(NoteFormatting.edit(action, text: source, selection: selection))
        let result = NSMutableString(string: source)
        for replacement in edit.replacements {
            #expect(NSMaxRange(replacement.range) <= result.length)
            result.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        #expect(NSMaxRange(edit.selection) <= result.length)
        return (result as String, edit.selection)
    }

    @Test("Bold preserves Unicode and selects the original text")
    func unicode() throws {
        let value = "Use 👩🏽‍💻 café here"
        let range = (value as NSString).range(of: "👩🏽‍💻 café")
        let (text, selection) = try apply(.bold, to: value, selection: range)
        #expect(text == "Use **👩🏽‍💻 café** here")
        #expect((text as NSString).substring(with: selection) == "👩🏽‍💻 café")
        let (unwrapped, restored) = try apply(.bold, to: text, selection: selection)
        #expect(unwrapped == value)
        #expect(restored == range)
    }

    @Test("Italic inside bold combines the styles and toggles independently")
    func combinedStyles() throws {
        let (text, selected) = try apply(.italic, to: "**hello**", selection: NSRange(location: 2, length: 5))
        #expect(text == "***hello***")
        let (restored, _) = try apply(.italic, to: text, selection: selected)
        #expect(restored == "**hello**")
    }

    @Test("Inline code chooses a delimiter that preserves embedded backticks")
    func backticks() throws {
        let (text, selected) = try apply(.code, to: "foo`bar", selection: NSRange(location: 0, length: 7))
        #expect(text == "``foo`bar``")
        let (restored, _) = try apply(.code, to: text, selection: selected)
        #expect(restored == "foo`bar")
    }

    @Test("Inline code preserves a JavaScript template literal at its edge")
    func templateLiteral() throws {
        let value = "const name = `hello`"
        let (text, selected) = try apply(.code, to: value, selection: NSRange(location: 0, length: (value as NSString).length))
        #expect(text == "`` const name = `hello` ``")
        let (restored, _) = try apply(.code, to: text, selection: selected)
        #expect(restored == value)
    }

    @Test("An empty selection inserts and selects useful placeholder text")
    func insertion() throws {
        let (text, selected) = try apply(.bold, to: "", selection: NSRange(location: 0, length: 0))
        #expect(text == "**bold text**")
        #expect((text as NSString).substring(with: selected) == "bold text")
    }

    @Test("A code block wraps selected code without discarding it")
    func codeBlock() throws {
        let code = "let name = \"café\"\nprint(name)"
        let (text, selected) = try apply(.codeBlock, to: code, selection: NSRange(location: 0, length: (code as NSString).length))
        #expect(text == "```\n\(code)\n```")
        #expect((text as NSString).substring(with: selected) == code)
    }

    @Test("Link insertion retains the label and escapes parentheses in its target")
    func link() throws {
        let (text, selected) = try apply(.link("https://example.com/a(b)"), to: "Read résumé", selection: NSRange(location: 5, length: 6))
        #expect(text == "Read [résumé](https://example.com/a\\(b\\))")
        #expect((text as NSString).substring(with: selected) == "résumé")
    }

    @Test("Every selected line becomes a list item, without changing the next line")
    func list() throws {
        let (text, _) = try apply(.bulletList, to: "one\ntwo\nthree", selection: NSRange(location: 0, length: 8))
        #expect(text == "- one\n- two\nthree")
    }

    @Test("Numbered lists increment across selected lines")
    func numberedList() throws {
        let (text, _) = try apply(.numberedList, to: "one\ntwo", selection: NSRange(location: 0, length: 7))
        #expect(text == "1. one\n2. two")
    }

    @Test("Applying the same list style removes its prefixes")
    func removeList() throws {
        let (text, _) = try apply(.bulletList, to: "- one\n- two", selection: NSRange(location: 0, length: 11))
        #expect(text == "one\ntwo")
    }

    @Test("Heading levels replace the existing heading prefix")
    func heading() throws {
        let (text, selected) = try apply(.heading(2), to: "# Title", selection: NSRange(location: 4, length: 0))
        #expect(text == "## Title")
        let (restored, _) = try apply(.heading(2), to: text, selection: selected)
        #expect(restored == "Title")
    }

    @Test("Empty notes can start with a heading or list")
    func emptyLines() throws {
        let (heading, _) = try apply(.heading(2), to: "", selection: NSRange(location: 0, length: 0))
        #expect(heading == "## ")
        let (list, _) = try apply(.bulletList, to: "", selection: NSRange(location: 0, length: 0))
        #expect(list == "- ")
    }

    @Test("Invalid selections and empty links cannot edit the document")
    func invalid() {
        #expect(NoteFormatting.edit(.bold, text: "abc", selection: NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(NoteFormatting.edit(.bold, text: "abc", selection: NSRange(location: 2, length: 9)) == nil)
        #expect(NoteFormatting.edit(.heading(9), text: "abc", selection: NSRange(location: 0, length: 0)) == nil)
        #expect(NoteFormatting.edit(.link(" "), text: "abc", selection: NSRange(location: 0, length: 0)) == nil)
    }
}
