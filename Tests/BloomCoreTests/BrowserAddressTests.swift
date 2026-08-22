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
