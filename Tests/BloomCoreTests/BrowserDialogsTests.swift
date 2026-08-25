import Foundation
import Testing
@testable import BloomCore

/// How the three questions a page can ask are put up, and what stops a page asking for ever.
@Suite("Browser dialogs")
struct BrowserDialogsTests {
    private static func shown(_ decision: BrowserDialogs.Decision) -> BrowserDialogs.Presentation? {
        guard case .show(let presentation) = decision else { return nil }
        return presentation
    }

    // MARK: - Whose words are whose

    @Test("Bloom's own line names the site, above whatever the page wrote")
    func theTitleNamesTheSite() {
        var dialogs = BrowserDialogs()
        let first = Self.shown(dialogs.request(.alert, message: "Saved", from: "localhost:3100"))
        #expect(first?.title == "localhost:3100 says")
        #expect(first?.message == "Saved")
    }

    @Test("A document with no host still gets a line")
    func anUnnamedPageStillHasATitle() {
        var dialogs = BrowserDialogs()
        #expect(Self.shown(dialogs.request(.alert, message: "Hello"))?.title == "This page says")
    }

    @Test("A message longer than a panel can hold is cut and says so")
    func aLongMessageIsCut() {
        var dialogs = BrowserDialogs()
        let huge = String(repeating: "a", count: 100_000)
        let presentation = Self.shown(dialogs.request(.alert, message: huge))
        #expect(presentation?.message.count == BrowserDialogs.messageLimit + 3)
        #expect(presentation?.message.hasSuffix("...") == true)
    }

    @Test("A message of nothing but newlines cannot grow the panel off the display")
    func aTallMessageIsCut() {
        var dialogs = BrowserDialogs()
        let tall = String(repeating: "line\n", count: 500)
        let message = Self.shown(dialogs.request(.alert, message: tall))?.message ?? ""
        #expect(message.split(separator: "\n").count == BrowserDialogs.lineLimit + 1)
    }

    @Test("Control characters go, so a dialog never draws as empty")
    func controlCharactersGo() {
        var dialogs = BrowserDialogs()
        let message = Self.shown(dialogs.request(.alert, message: "a\u{0}\u{7}\u{1B}b\nc\td"))?.message
        #expect(message == "ab\nc\td")
    }

    @Test("A prompt's starting text is one line, and only a prompt has one")
    func promptTextIsOneLine() {
        var dialogs = BrowserDialogs()
        let prompt = Self.shown(dialogs.request(.prompt, message: "Name?", defaultText: "a\nb\tc"))
        #expect(prompt?.defaultText == "a b c")

        let confirm = Self.shown(dialogs.request(.confirm, message: "Sure?", defaultText: "ignored"))
        #expect(confirm?.defaultText == "")
    }

    // MARK: - How many

    @Test("The first dialog is asked plainly, and the second offers a way out")
    func theSecondOffersAWayOut() {
        var dialogs = BrowserDialogs()
        #expect(Self.shown(dialogs.request(.alert, message: "one"))?.offersSuppression == false)
        #expect(Self.shown(dialogs.request(.alert, message: "two"))?.offersSuppression == true)
        #expect(Self.shown(dialogs.request(.alert, message: "three"))?.offersSuppression == true)
    }

    @Test("A silenced page puts nothing on screen, however many times it asks")
    func silencingHolds() {
        var dialogs = BrowserDialogs()
        _ = dialogs.request(.alert, message: "one")
        _ = dialogs.request(.alert, message: "two")
        dialogs.silence()
        #expect(dialogs.isSilent)
        for _ in 0..<1_000 {
            #expect(dialogs.request(.confirm, message: "again") == .suppress)
        }
    }

    @Test("A navigation undoes the silencing and starts the count again")
    func aNavigationResetsIt() {
        var dialogs = BrowserDialogs()
        _ = dialogs.request(.alert, message: "one")
        _ = dialogs.request(.alert, message: "two")
        dialogs.silence()

        dialogs.pageCommitted()
        #expect(!dialogs.isSilent)
        #expect(Self.shown(dialogs.request(.alert, message: "one again"))?.offersSuppression == false)
    }
}
