import Foundation
import Testing
@testable import BloomCore

/// Who a page says it is, on the panels a page can raise.
@Suite("Browser page origin")
struct BrowserPageOriginTests {
    @Test("A dev server is named by host and port, which is what tells two worktrees apart")
    func aDevServerKeepsItsPort() {
        #expect(BrowserPageOrigin.name(scheme: "http", host: "localhost", port: 3100)
            == "localhost:3100")
    }

    @Test("The default port for the scheme is left off")
    func theDefaultPortIsDropped() {
        #expect(BrowserPageOrigin.name(scheme: "https", host: "example.com", port: 443)
            == "example.com")
        #expect(BrowserPageOrigin.name(scheme: "http", host: "example.com", port: 80)
            == "example.com")
        #expect(BrowserPageOrigin.name(scheme: "https", host: "example.com", port: 0)
            == "example.com")
        #expect(BrowserPageOrigin.name(scheme: "https", host: "example.com", port: 8443)
            == "example.com:8443")
    }

    @Test("A document with no host is not a site and has no name")
    func anOpaqueOriginHasNoName() {
        #expect(BrowserPageOrigin.name(scheme: "file", host: "", port: 0) == nil)
        #expect(BrowserPageOrigin.name(scheme: "", host: "  ", port: 0) == nil)
    }

    @Test("The file panel says who is asking and what happens to what is chosen")
    func theUploadMessageNamesThePage() {
        let one = BrowserPageOrigin.uploadMessage(from: "localhost:3100", allowsMultiple: false)
        #expect(one == "Choose the file you want to give localhost:3100.")

        let many = BrowserPageOrigin.uploadMessage(from: "localhost:3100", allowsMultiple: true)
        #expect(many == "Choose the files you want to give localhost:3100.")
    }

    @Test("A page with no name still gets a sentence")
    func theUploadMessageSurvivesAnUnnamedPage() {
        let message = BrowserPageOrigin.uploadMessage(from: nil, allowsMultiple: false)
        #expect(message == "Choose the file you want to give this page.")
    }
}
