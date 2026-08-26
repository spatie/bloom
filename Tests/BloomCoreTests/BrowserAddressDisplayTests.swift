import Testing
@testable import BloomCore

/// The split behind the two-tone address, which is the one thing in the browser bar that can be
/// got dangerously wrong: the strong ink has to land on the host that is really serving the page.
@Suite("Browser address display")
struct BrowserAddressDisplayTests {
    @Test("The host is the emphasised run, and the scheme and path are not")
    func splitsAnOrdinaryAddress() {
        let display = BrowserAddressDisplay.of("https://spatie.be/docs/laravel-medialibrary")
        #expect(display.leading == "https://")
        #expect(display.host == "spatie.be")
        #expect(display.trailing == "/docs/laravel-medialibrary")
    }

    @Test("The port travels with the host, because a dev server IS its port")
    func portIsPartOfTheHost() {
        let display = BrowserAddressDisplay.of("http://localhost:3100/settings")
        #expect(display.host == "localhost:3100")
        #expect(display.trailing == "/settings")
    }

    @Test("Query and fragment stay in the quiet run")
    func queryAndFragmentAreQuiet() {
        let display = BrowserAddressDisplay.of("https://example.com/a?b=c#d")
        #expect(display.host == "example.com")
        #expect(display.trailing == "/a?b=c#d")
    }

    @Test("A username is not the host, however much it looks like one")
    func userInfoIsNeverEmphasised() {
        let display = BrowserAddressDisplay.of("https://spatie.be@evil.example/login")
        #expect(display.host == "evil.example")
        #expect(display.leading == "https://spatie.be@")
        #expect(display.security == .secure)
    }

    @Test("The three runs still spell the address they were split from", arguments: [
        "https://spatie.be/docs",
        "http://localhost:3100/",
        "https://example.com/a?b=c#d",
        "https://user:secret@example.com/x",
    ])
    func runsRejoinIntoTheAddress(address: String) {
        let display = BrowserAddressDisplay.of(address)
        #expect(display.leading + display.host + display.trailing == address)
    }

    @Test("What the glyph says about the connection")
    func securityIsReadOffTheScheme() {
        #expect(BrowserAddressDisplay.of("https://example.com/").security == .secure)
        #expect(BrowserAddressDisplay.of("http://localhost:3100/").security == .local)
        #expect(BrowserAddressDisplay.of("http://127.0.0.1:8080/").security == .local)
        #expect(BrowserAddressDisplay.of("http://myapp.localhost/").security == .local)
        #expect(BrowserAddressDisplay.of("http://example.com/").security == .insecure)
        #expect(BrowserAddressDisplay.of("").security == .none)
        #expect(BrowserAddressDisplay.of("").symbolIsAbsent)
    }

    @Test("Anything that will not parse is drawn plainly rather than half emphasised")
    func unparsedTextIsAllQuiet() {
        let display = BrowserAddressDisplay.of("not an address")
        #expect(display.host.isEmpty)
        #expect(display.leading == "not an address")
        #expect(display.security == .none)
    }

    @Test("An empty field has nothing to draw, so the placeholder is left to AppKit")
    func emptyIsEmpty() {
        #expect(BrowserAddressDisplay.of("").isEmpty)
        #expect(!BrowserAddressDisplay.of("https://example.com/").isEmpty)
    }

    @Test("A right-to-left override cannot reverse what the field draws")
    func bidiOverridesAreStripped() {
        let display = BrowserAddressDisplay.of("https://example.com/\u{202E}gnp.exe")
        #expect(display.trailing == "/gnp.exe")
        #expect(!display.trailing.unicodeScalars.contains { $0.value == 0x202E })
    }

    @Test("A newline cannot draw a second line into the bar")
    func controlCharactersAreStripped() {
        let display = BrowserAddressDisplay.of("https://example.com/a\nb")
        #expect(display.trailing == "/ab")
    }

    @Test("An address of several kilobytes is cut before anything tries to lay it out")
    func absurdAddressesAreCapped() {
        let long = "https://example.com/" + String(repeating: "a", count: 4000)
        let display = BrowserAddressDisplay.of(long)
        #expect(display.leading.count + display.host.count + display.trailing.count
            <= BrowserAddressDisplay.limit + 1)
    }
}

private extension BrowserAddressDisplay {
    /// Nothing to certify, so nothing is drawn at the left end of the field.
    var symbolIsAbsent: Bool { security.symbol == nil && security.help == nil }
}
