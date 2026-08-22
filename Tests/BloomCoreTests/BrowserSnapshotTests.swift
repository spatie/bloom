import Foundation
import Testing
@testable import BloomCore

@Suite("Browser snapshot names")
struct BrowserSnapshotTests {
    private let moment = Date(timeIntervalSince1970: 1_755_871_511)
    private let utc = TimeZone(identifier: "UTC")!

    @Test("A dev server's host and port are what tells one snapshot from another")
    func labelsHostAndPort() {
        #expect(BrowserSnapshot.label(for: "http://localhost:5173/") == "localhost-5173")
    }

    @Test("The path is kept, because the route is what the screenshot is of")
    func labelsPath() {
        #expect(
            BrowserSnapshot.label(for: "https://example.com/docs/intro") == "example.com-docs-intro"
        )
    }

    @Test("A query string is dropped rather than spelled out in a filename")
    func dropsQuery() {
        #expect(BrowserSnapshot.label(for: "https://example.com/a?b=c&d=e") == "example.com-a")
    }

    @Test("Nothing that could change what a path means survives into a name")
    func sanitises() {
        let label = BrowserSnapshot.label(for: "http://localhost:3000/a b/c:d")
        #expect(!label.contains("/"))
        #expect(!label.contains(":"))
        #expect(!label.hasPrefix("."))
    }

    @Test("A long address is cut rather than allowed to fill the chip")
    func trims() {
        let long = "https://example.com/" + String(repeating: "segment/", count: 20)
        #expect(BrowserSnapshot.label(for: long).count <= BrowserSnapshot.maxLabelLength)
    }

    @Test("An address the pane never loaded leaves the date to name the file")
    func emptyAddress() {
        #expect(BrowserSnapshot.label(for: "") == "")
        let name = BrowserSnapshot.filename(for: "", at: moment, timeZone: utc)
        #expect(name == "Page 2025-08-22 at 14.05.11.png")
    }

    @Test("The name is the address, then the moment, then png")
    func filename() {
        let name = BrowserSnapshot.filename(for: "http://localhost:5173/", at: moment, timeZone: utc)
        #expect(name == "localhost-5173 2025-08-22 at 14.05.11.png")
    }

    @Test("Two shots of the same page in the same second are still two different chips")
    func uniques() {
        let first = BrowserSnapshot.filename(for: "http://localhost:5173/", at: moment, timeZone: utc)
        let second = BrowserSnapshot.filename(
            for: "http://localhost:5173/", at: moment, avoiding: [first], timeZone: utc
        )
        #expect(first != second)
        #expect(second.hasSuffix(".png"))
    }
}
