import Foundation
import Testing
@testable import BloomCore

/// What a page gets when it asks for a window of its own, and what a page in a loop gets.
@Suite("Browser popups")
struct BrowserPopupsTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let page = URL(string: "http://localhost:3100/next")!

    @Test("An ordinary link that opens in a new tab gets one")
    func aLinkOpens() {
        var popups = BrowserPopups()
        #expect(popups.request(Self.page, at: Self.start) == .open(Self.page))
    }

    @Test("A page cannot open more than the limit in one burst")
    func aBurstIsCapped() {
        var popups = BrowserPopups(limit: 3, window: 5)
        for step in 0..<3 {
            let at = Self.start.addingTimeInterval(Double(step) / 100)
            #expect(popups.request(Self.page, at: at) == .open(Self.page))
        }

        let fourth = popups.request(Self.page, at: Self.start.addingTimeInterval(0.04))
        guard case .refuseAndSay = fourth else {
            Issue.record("the fourth window in a burst should be refused, got \(fourth)")
            return
        }
    }

    @Test("Only the first refusal in a run says anything, so a loop puts up one dialog")
    func onlyTheFirstRefusalSpeaks() {
        var popups = BrowserPopups(limit: 1, window: 5)
        #expect(popups.request(Self.page, at: Self.start) == .open(Self.page))

        let first = popups.request(Self.page, at: Self.start.addingTimeInterval(0.01))
        guard case .refuseAndSay = first else {
            Issue.record("the first refusal should carry a notice, got \(first)")
            return
        }
        for step in 2..<200 {
            let at = Self.start.addingTimeInterval(Double(step) / 100)
            #expect(popups.request(Self.page, at: at) == .refuse)
        }
    }

    @Test("The notice names the host and nothing else of the address")
    func theNoticeNamesTheHost() {
        var popups = BrowserPopups(limit: 0, window: 5)
        let url = URL(string: "https://example.com/a/very/long/path?token=secret")!
        guard case .refuseAndSay(let notice) = popups.request(url, at: Self.start) else {
            Issue.record("a limit of none should refuse and say so")
            return
        }
        #expect(notice.title.contains("example.com"))
        #expect(!notice.title.contains("secret"))
        #expect(!notice.message.contains("secret"))
    }

    @Test("A reader clicking a link a minute later is not held to the last refusal")
    func theWindowRolls() {
        var popups = BrowserPopups(limit: 1, window: 5)
        #expect(popups.request(Self.page, at: Self.start) == .open(Self.page))
        #expect(popups.request(Self.page, at: Self.start.addingTimeInterval(1)) != .open(Self.page))
        #expect(popups.request(Self.page, at: Self.start.addingTimeInterval(60)) == .open(Self.page))
    }

    @Test("An allowed opening arms the notice again, so a second loop is also reported")
    func aSecondLoopIsAlsoReported() {
        var popups = BrowserPopups(limit: 1, window: 5)
        _ = popups.request(Self.page, at: Self.start)
        _ = popups.request(Self.page, at: Self.start.addingTimeInterval(0.01))
        #expect(popups.request(Self.page, at: Self.start.addingTimeInterval(60)) == .open(Self.page))

        let again = popups.request(Self.page, at: Self.start.addingTimeInterval(60.01))
        guard case .refuseAndSay = again else {
            Issue.record("a fresh run of refusals should say so once, got \(again)")
            return
        }
    }

    @Test("A scheme the pane cannot show is refused without a word")
    func anUnshowableSchemeIsQuiet() {
        var popups = BrowserPopups()
        #expect(popups.request(URL(string: "mailto:someone@example.com"), at: Self.start) == .refuse)
        #expect(popups.request(URL(string: "bloom://open/workspace"), at: Self.start) == .refuse)
        #expect(popups.request(URL(string: "file:///etc/passwd"), at: Self.start) == .refuse)
    }

    @Test("A refused scheme costs the page nothing from its allowance")
    func aRefusedSchemeIsNotCounted() {
        var popups = BrowserPopups(limit: 1, window: 5)
        #expect(popups.request(URL(string: "mailto:someone@example.com"), at: Self.start) == .refuse)
        #expect(popups.request(Self.page, at: Self.start) == .open(Self.page))
    }

    @Test("window.open with no address does nothing")
    func anEmptyWindowIsRefused() {
        var popups = BrowserPopups()
        #expect(popups.request(nil, at: Self.start) == .refuse)
    }
}
