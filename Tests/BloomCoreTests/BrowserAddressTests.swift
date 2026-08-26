import Testing
@testable import BloomCore

/// The address field's one rule, which lived on the browser session until nothing could test it.
@Suite("Browser address")
struct BrowserAddressTests {
    @Test("Local hosts get http, because a dev server rarely has a certificate", arguments: [
        "localhost:3100",
        "127.0.0.1:8080/health",
        "0.0.0.0:4000",
        "myapp.localhost",
    ])
    func localHostsGetHTTP(text: String) {
        #expect(BrowserAddress.url(from: text)?.absoluteString == "http://" + text)
    }

    @Test("A dotted host gets https")
    func dottedHostGetsHTTPS() {
        #expect(BrowserAddress.url(from: "example.com/docs")?.absoluteString == "https://example.com/docs")
    }

    @Test("An explicit scheme is taken as written")
    func explicitSchemeStands() {
        #expect(BrowserAddress.url(from: "http://example.com")?.absoluteString == "http://example.com")
        #expect(BrowserAddress.url(from: "https://example.com")?.absoluteString == "https://example.com")
    }

    @Test("Whitespace is trimmed, not tolerated inside", arguments: [
        ("  localhost:3100  ", true),
        ("not an address", false),
    ])
    func whitespaceRules(text: String, accepted: Bool) {
        #expect((BrowserAddress.url(from: text) != nil) == accepted)
    }

    @Test("A bare word with no dot and no scheme is not an address", arguments: [
        "readme", "", "settings"
    ])
    func bareWordsRefused(text: String) {
        #expect(BrowserAddress.url(from: text) == nil)
    }
}

/// What a browser pane will hand to the Mac's own browser, which is a security gate: the address
/// comes off a page, and `NSWorkspace` opens whatever scheme it is given.
@Suite("Opening a page outside Bloom")
struct BrowserAddressExternalTests {
    @Test("A page the pane is really on is handed over as it stands", arguments: [
        "https://example.com/docs",
        "http://localhost:3100/health",
        "http://127.0.0.1:8080",
        "https://example.com/a?b=c#d",
    ])
    func pagesOpen(address: String) {
        #expect(BrowserAddress.external(from: address)?.absoluteString == address)
    }

    @Test("A scheme that is not the web is refused", arguments: [
        "javascript://example.com/%0aalert(1)",
        "javascript:alert(1)",
        "file:///Applications/Calculator.app",
        "file:///Users/someone/.zshrc",
        "about:blank",
        "data:text/html,<script>alert(1)</script>",
        "mailto:someone@example.com",
        "x-apple-something://run/this",
    ])
    func otherSchemesRefused(address: String) {
        #expect(BrowserAddress.external(from: address) == nil)
    }

    @Test("A pane that has been nowhere has nothing to open", arguments: [
        "", "   ", "http://", "https:///docs",
    ])
    func nothingToOpen(address: String) {
        #expect(BrowserAddress.external(from: address) == nil)
    }

    @Test("A half-written address is not one, because a page always knows its own scheme", arguments: [
        "example.com", "localhost:3100", "not an address",
    ])
    func nothingIsCompleted(address: String) {
        #expect(BrowserAddress.external(from: address) == nil)
    }

    @Test("The host is the parser's, so a name before an @ is not mistaken for one")
    func credentialsDoNotMoveTheHost() {
        let url = BrowserAddress.external(from: "https://example.com@evil.example/login")
        #expect(url?.host() == "evil.example")
    }
}
