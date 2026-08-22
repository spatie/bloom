import Foundation
import Testing
@testable import BloomCore

/// The transcript's address rules, which lived beside the views until nothing could test the one
/// security gate an agent's markdown reaches.
@Suite("Link policy")
struct LinkPolicyTests {
    // MARK: - The gate

    @Test("Web and mail schemes open", arguments: [
        "https://example.com/page",
        "http://localhost:3100",
        "mailto:owner@example.com",
        "HTTPS://EXAMPLE.COM",
    ])
    func allowedSchemesOpen(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(LinkPolicy.opens(url))
    }

    @Test("Everything else is refused", arguments: [
        "file:///Applications/Something.app",
        "javascript:alert(1)",
        "x-apple.systempreferences:com.apple.preference",
        "ftp://example.com/file",
        "shortcuts://run-shortcut?name=x",
    ])
    func otherSchemesAreRefused(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!LinkPolicy.opens(url))
    }

    @Test("No scheme at all is refused")
    func schemelessIsRefused() throws {
        let url = try #require(URL(string: "example.com/page"))
        #expect(!LinkPolicy.opens(url))
    }

    // MARK: - Menu titles

    @Test("A short address loses only its scheme")
    func shortAddressLosesScheme() {
        #expect(LinkPolicy.shortened("https://example.com/a") == "example.com/a")
        #expect(LinkPolicy.shortened("http://example.com") == "example.com")
    }

    @Test("A long address is cut at 47 characters plus an ellipsis")
    func longAddressIsCut() {
        let long = "https://example.com/" + String(repeating: "a", count: 60)
        let shortened = LinkPolicy.shortened(long)
        #expect(shortened.count == 48)
        #expect(shortened.hasSuffix("\u{2026}"))
        #expect(shortened.hasPrefix("example.com/"))
    }

    @Test("Exactly 48 characters is left whole")
    func boundaryIsLeftWhole() {
        let value = String(repeating: "b", count: 48)
        #expect(LinkPolicy.shortened(value) == value)
    }

    // MARK: - What prose offers

    @Test("Plain text yields its addresses in order, once each")
    func plainTextAddresses() {
        let text = "See https://a.example and https://b.example, then https://a.example again."
        #expect(LinkPolicy.addresses(in: text) == ["https://a.example", "https://b.example"])
    }

    @Test("Markdown links are collected through nesting, and the gate applies")
    func markdownAddresses() {
        let blocks: [MarkdownBlock] = [
            .paragraph(inline: [
                .link(text: [.text("settings")], url: "https://a.example/settings"),
                .emphasis([.link(text: [.text("nested")], url: "https://b.example")]),
                .link(text: [.text("app")], url: "file:///Applications/X.app"),
            ]),
            .blockQuote(blocks: [
                .paragraph(inline: [.link(text: [.text("again")], url: "https://a.example/settings")]),
            ]),
        ]
        #expect(LinkPolicy.addresses(in: blocks) == [
            "https://a.example/settings",
            "https://b.example",
        ])
    }

    @Test("A fenced block is quoted text and offers nothing")
    func codeOffersNothing() {
        let blocks: [MarkdownBlock] = [
            .codeBlock(code: "curl https://a.example", language: .plainText, info: ""),
            .paragraph(inline: [.code("https://b.example")]),
        ]
        #expect(LinkPolicy.addresses(in: blocks).isEmpty)
    }
}
