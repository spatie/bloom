import Testing
import Foundation
@testable import BloomCore

/// The transcript this is about: an agent asked to check whether a page loaded, was handed an
/// address with no title, no text and a picture of Bloom's error card, and spent a dozen turns
/// concluding that the browser pane itself was broken while the pane was displaying the reason in
/// words. See `BrowserPaneReport.failure`.
@Suite("What a browser pane says when its page did not load")
struct BrowserPaneTroubleTests {
    private static func report(failure: BrowserLoadFailure?) -> BrowserPaneReport {
        BrowserPaneReport(
            number: 1,
            name: "Service Tokens",
            address: "http://there-there-6.test/",
            failure: failure
        )
    }

    /// The key is written even when the page is fine, so a reader of this object can tell "the
    /// load succeeded" from "this build does not report it". Read out of the object rather than
    /// through `JSONValue`'s subscript, which answers nil for a null on purpose.
    @Test func aPaneShowingAPageHasNothingToSay() {
        let report = Self.report(failure: nil)
        #expect(report.trouble == nil)
        #expect(report.json.objectValue?["failed_to_load"] == .null)
    }

    /// The words are the pane's own, so the model and the person beside it read one account.
    @Test func namesWhatWentWrongInTheSameWordsThePaneDraws() {
        let failure = try? #require(
            BrowserLoadFailure.of(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, host: "there-there-6.test")
        )
        let trouble = try? #require(Self.report(failure: failure).trouble)

        #expect(trouble?.contains("Cannot connect") == true)
        #expect(trouble?.contains("there-there-6.test") == true)
        // The conclusion the agent got wrong, said out loud.
        #expect(trouble?.contains("not the pane failing to draw") == true)
    }

    /// A failure that is about the machine rather than about this page does not repeat an address
    /// that had nothing to do with it.
    @Test func leavesTheAddressOutWhereItIsNotTheSubject() {
        let failure = BrowserLoadFailure.of(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet
        )
        let trouble = Self.report(failure: failure).trouble

        #expect(trouble?.contains("there-there-6.test") == false)
        #expect(trouble?.contains("No internet connection") == true)
    }

    /// `browser_read` is the tool the other five point at, so the fact has to be on its object as
    /// well as in the sentences.
    @Test func carriesItOnTheObjectBrowserReadAnswersWith() {
        let failure = BrowserLoadFailure.of(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let json = Self.report(failure: failure).json

        #expect(json["failed_to_load"]?.stringValue?.contains("took too long") == true)
    }

    /// The three that are a normal part of browsing still draw nothing and still report nothing:
    /// a cancelled load, a response that became a download, and a policy refusal.
    @Test func saysNothingAboutTheFailuresThatAreNotFailures() {
        #expect(BrowserLoadFailure.of(domain: NSURLErrorDomain, code: NSURLErrorCancelled) == nil)
        #expect(BrowserLoadFailure.of(domain: "WebKitErrorDomain", code: 102) == nil)
        #expect(BrowserLoadFailure.of(domain: "WebKitErrorDomain", code: 101) == nil)
    }
}
