import Foundation
import Testing
@testable import BloomCore

/// What a split of the centre column produces, which is also what decides whether the View menu
/// offers one. Both sides read this, and the reason it is here rather than beside the pane's own
/// view is that they used to disagree: Split Right was enabled whenever a workspace was selected,
/// and then did nothing at all on the review tab and the Notes tab.
@Suite("PaneSplit")
struct PaneSplitTests {
    private let chat = PaneContent.chat(SessionID(rawValue: "s-one"))
    private let tool = PaneContent.tool("t-one")

    @Test("a conversation splits into the same conversation")
    func chatSplits() {
        #expect(PaneSplit.duplicating(chat, tabKind: nil) == .sameContent)
        #expect(PaneSplit.duplicating(chat, tabKind: nil).opensAPane)
    }

    @Test("a shell and a page are one live view each, so the split gets a fresh one")
    func toolsGetAFreshOne() {
        #expect(PaneSplit.duplicating(tool, tabKind: .terminal) == .freshTerminal)
        #expect(PaneSplit.duplicating(tool, tabKind: .browser) == .freshBrowser)
    }

    @Test("the review and the notes cannot be split, so the menu has to grey rather than lie")
    func theOnesWithNoSecondCopy() {
        #expect(PaneSplit.duplicating(tool, tabKind: .review) == .nothing)
        #expect(PaneSplit.duplicating(tool, tabKind: .notes) == .nothing)
        #expect(!PaneSplit.duplicating(tool, tabKind: .review).opensAPane)
        #expect(!PaneSplit.duplicating(tool, tabKind: .notes).opensAPane)
    }

    @Test("a pointer at a tab that has been closed opens nothing either")
    func missingTab() {
        #expect(PaneSplit.duplicating(tool, tabKind: nil) == .nothing)
    }

    @Test("every kind is decided, so a new one cannot arrive enabled by default")
    func everyKindIsAnswered() {
        let splittable = CenterTabKind.allCases.filter {
            PaneSplit.duplicating(tool, tabKind: $0).opensAPane
        }
        #expect(Set(splittable) == [.terminal, .browser])
    }

    /// The raw values are what `center.tabs.<workspaceID>` was written with, and the move into the
    /// core must not have changed a byte of them.
    @Test("the stored spellings survived the move into the core")
    func wireFormat() {
        #expect(CenterTabKind.allCases.map(\.rawValue) == ["terminal", "browser", "review", "notes"])
    }

    // MARK: - Which row of a Split submenu carries the key

    /// The View menu's Split Right offers Chat, Terminal and Browser, and `Cmd+\` is drawn on
    /// whichever of the three means "this pane again". A key on the parent would be drawn beside a
    /// row AppKit never fires.
    @Test("the same again row is the kind a duplicate would have produced")
    func theRowThatCarriesTheKey() {
        #expect(PaneSplit.duplicating(chat, tabKind: nil).sameAgainKind == .chat)
        #expect(PaneSplit.duplicating(tool, tabKind: .terminal).sameAgainKind == .terminal)
        #expect(PaneSplit.duplicating(tool, tabKind: .browser).sameAgainKind == .browser)
    }

    /// The review and the notes have no second copy, so there is no row to put the key on and the
    /// whole submenu greys. The two answers have to agree, or a greyed submenu would still be
    /// eating `Cmd+\`.
    @Test("a pane that cannot be split has no row for the key")
    func noRowWhenNothingOpens() {
        for kind in [CenterTabKind.review, .notes] {
            let outcome = PaneSplit.duplicating(tool, tabKind: kind)
            #expect(outcome.sameAgainKind == nil, "\(kind)")
            #expect(!outcome.opensAPane, "\(kind)")
        }
        #expect(PaneSplit.duplicating(tool, tabKind: nil).sameAgainKind == nil)
    }

    /// Said as one rule rather than four cases, because these are the two halves of one question
    /// and a new outcome must not be able to answer them differently.
    @Test("an outcome opens a pane exactly when it has a row to put the key on")
    func theTwoAnswersAgree() {
        let outcomes: [PaneDuplicateOutcome] = [.sameContent, .freshTerminal, .freshBrowser, .nothing]
        for outcome in outcomes {
            #expect(outcome.opensAPane == (outcome.sameAgainKind != nil), "\(outcome)")
        }
    }
}
