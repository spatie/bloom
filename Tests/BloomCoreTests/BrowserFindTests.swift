import Foundation
import Testing
@testable import BloomCore

/// Find in Page: what the bar says, and what the keyboard means to it.
@Suite("Browser find")
struct BrowserFindTests {
    @Test("A pane that has never been searched says nothing and can step nowhere")
    func anIdleFindIsQuiet() {
        let find = BrowserFind()
        #expect(!find.isShowing)
        #expect(!find.canStep)
        #expect(find.status == "")
    }

    @Test("A search that found nothing says so, and one that found something does not")
    func onlyAFailureSpeaks() {
        var find = BrowserFind()
        find.type("widget")
        find.settle(matched: false)
        #expect(find.status == "Not found")

        find.settle(matched: true)
        #expect(find.status == "")
    }

    @Test("Emptying the field is not a search that failed")
    func anEmptyFieldClearsTheFailure() {
        var find = BrowserFind()
        find.type("widget")
        find.settle(matched: false)
        find.type("")
        #expect(find.status == "")
        #expect(!find.canStep)
    }

    @Test("An answer for a field that has since been emptied is not shown")
    func aLateAnswerIsIgnored() {
        var find = BrowserFind()
        find.type("")
        find.settle(matched: false)
        #expect(find.status == "")
    }

    @Test("Capitals in the query are what makes the search respect them")
    func smartCase() {
        var find = BrowserFind()
        find.type("submit")
        #expect(!find.isCaseSensitive)

        find.type("userId")
        #expect(find.isCaseSensitive)
    }

    @Test("Closing the bar keeps the query, so reopening steps the same search")
    func theQuerySurvivesClosing() {
        var find = BrowserFind()
        find.show()
        find.type("widget")
        find.hide()
        #expect(!find.isShowing)
        #expect(find.query == "widget")

        find.show()
        #expect(find.canStep)
    }

    // MARK: - What the keyboard means

    @Test("The three find keys, and only those three")
    func theFindKeys() {
        #expect(BrowserFindCommand.forKey("f", hasCommand: true, hasShift: false) == .show)
        #expect(BrowserFindCommand.forKey("g", hasCommand: true, hasShift: false) == .next)
        #expect(BrowserFindCommand.forKey("G", hasCommand: true, hasShift: true) == .previous)
    }

    @Test("A press with no command key is not ours, whatever the letter")
    func plainLettersFallThrough() {
        #expect(BrowserFindCommand.forKey("f", hasCommand: false, hasShift: false) == nil)
        #expect(BrowserFindCommand.forKey("g", hasCommand: false, hasShift: false) == nil)
    }

    @Test("Every other command key falls through to whatever else wants it")
    func otherKeysFallThrough() {
        for key in ["w", "r", "l", "s", "1", "["] {
            #expect(BrowserFindCommand.forKey(key, hasCommand: true, hasShift: false) == nil)
            #expect(BrowserFindCommand.forKey(key, hasCommand: true, hasShift: true) == nil)
        }
        // Shift Cmd F is the cross-transcript search screen's, not this pane's.
        #expect(BrowserFindCommand.forKey("f", hasCommand: true, hasShift: true) == nil)
    }
}
