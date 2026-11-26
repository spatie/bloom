import Foundation
import Testing
@testable import BloomCore

@Suite("Where a streamed answer's new rendering parts from the text already on screen")
struct AttributedTextDivergenceTests {
    /// A key of the test's own: the link and font keys are AppKit's, which the core cannot import.
    private static var linked: [NSAttributedString.Key: Any] {
        [NSAttributedString.Key("test.link"): "https://example.test"]
    }

    private static func text(_ string: String, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        NSAttributedString(string: string, attributes: attributes)
    }

    private static func joined(_ parts: NSAttributedString...) -> NSAttributedString {
        let result = NSMutableAttributedString()
        parts.forEach(result.append)
        return result
    }

    @Test("a delta appended to the answer parts at the old end")
    func appended() {
        let offset = AttributedTextDivergence.firstDifference(Self.text("Hello"), Self.text("Hello, world"))
        #expect(offset == 5)
    }

    @Test("identical text parts nowhere")
    func identical() {
        let offset = AttributedTextDivergence.firstDifference(Self.text("Same"), Self.text("Same"))
        #expect(offset == 4)
    }

    @Test("an empty view parts at the start")
    func empty() {
        let offset = AttributedTextDivergence.firstDifference(Self.text(""), Self.text("New"))
        #expect(offset == 0)
    }

    @Test("a changed character parts where it changed")
    func changedCharacter() {
        let offset = AttributedTextDivergence.firstDifference(Self.text("abcdef"), Self.text("abXdef"))
        #expect(offset == 2)
    }

    /// Markdown can restyle text already shown: a closing bracket turns the run before it into a link.
    @Test("same characters restyled part where the style changes")
    func restyled() {
        let old = Self.text("plain [word")
        let new = Self.joined(Self.text("plain "), Self.text("[word", attributes: Self.linked))
        let offset = AttributedTextDivergence.firstDifference(old, new)
        #expect(offset == 6)
    }

    @Test("attributes split into different runs but equal everywhere part nowhere")
    func differentRunsSameAttributes() {
        let old = Self.text("abcdef", attributes: Self.linked)
        let new = Self.joined(Self.text("abc", attributes: Self.linked), Self.text("def", attributes: Self.linked))
        let offset = AttributedTextDivergence.firstDifference(old, new)
        #expect(offset == 6)
    }

    /// A flag is two UTF-16 pairs; the edit must replace it whole rather than leave half behind.
    @Test("a difference inside a composed character parts at its start")
    func composedCharacter() {
        let offset = AttributedTextDivergence.firstDifference(Self.text("a🇫🇷"), Self.text("a🇫🇮"))
        #expect(offset == 1)
    }

    @Test("a shorter rendering parts at its own end")
    func shortened() {
        let offset = AttributedTextDivergence.firstDifference(Self.text("abcdef"), Self.text("abc"))
        #expect(offset == 3)
    }
}
