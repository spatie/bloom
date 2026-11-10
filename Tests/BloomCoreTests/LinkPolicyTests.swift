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

    @Test("Opening rechecks the current allowlist")
    func revokedSchemeDoesNotOpen() throws {
        let url = try #require(URL(string: "linear://team/issue/T-123"))
        #expect(LinkPolicy.opens(url, allowedSchemes: ["linear"]))
        #expect(!LinkPolicy.opens(url))
        #expect(!LinkPolicy.opens(url, allowedSchemes: ["slack"]))
        #expect(LinkPolicy.opens(url, allowedSchemes: ["LINEAR"]))
    }

    @Test("Reserved schemes cannot be enabled", arguments: [
        "file:///tmp/private", "javascript:alert(1)", "bloom://workspace/123",
        "bloomdev://workspace/123", "bloom-source://file?path=/tmp/private", "BLOOM-FUTURE://internal",
    ])
    func reservedSchemesCannotOpen(address: String) throws {
        let url = try #require(URL(string: address))
        let scheme = try #require(url.scheme)
        #expect(!LinkPolicy.opens(url, allowedSchemes: [scheme]))
    }

    @Test("Scheme names are normalised, with invalid and reserved entries ignored")
    func settingsSchemes() {
        #expect(TranscriptLinkPreferences.schemes(in: "").isEmpty)
        #expect(TranscriptLinkPreferences.schemes(in: " LINEAR, slack; linear\nfigma notion zoommtg ")
            == ["linear", "slack", "figma", "notion", "zoommtg"])
        #expect(TranscriptLinkPreferences.schemes(in: "bloomberg") == ["bloomberg"])
        #expect(TranscriptLinkPreferences.schemes(in: "file, JAVASCRIPT, bloom, bloomdev, bloom-source, 1app, app://, üapp").isEmpty)
    }

    @Test("Markdown parsing caches include the app scheme policy")
    func markdownSchemeChanges() {
        let source = "Open linear://team/T-123 and [the channel](slack://channel?id=C1)."
        let enabled = MarkdownParser.parse(source, allowedSchemes: ["linear", "slack"])
        #expect(LinkPolicy.addresses(in: enabled, allowedSchemes: ["linear", "slack"])
            == ["linear://team/T-123", "slack://channel?id=C1"])
        let disabled = MarkdownParser.parse(source)
        #expect(LinkPolicy.addresses(in: disabled).isEmpty)
        #expect(LinkPolicy.addresses(in: disabled, allowedSchemes: ["linear"]).isEmpty)
        #expect(MarkdownParser.parse(source, allowedSchemes: ["linear", "slack"]) == enabled)
    }

    @Test("Autolinks retain normalised local server targets")
    func localAutolinkTargets() {
        let blocks = MarkdownParser.parse("<localhost:3000> and <127.0.0.1:8080>")
        #expect(LinkPolicy.addresses(in: blocks) == ["http://localhost:3000", "http://127.0.0.1:8080"])
    }

    @Test("App schemes reach nested markdown and autolinks")
    func nestedAppLinks() {
        let source = """
        > **linear://team/T-1**

        - [ ] <linear://team/T-2>

        | Link |
        | --- |
        | linear://team/T-3 |
        """
        let blocks = MarkdownParser.parse(source, allowedSchemes: ["linear"])
        #expect(LinkPolicy.addresses(in: blocks, allowedSchemes: ["linear"])
            == ["linear://team/T-1", "linear://team/T-2", "linear://team/T-3"])
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
