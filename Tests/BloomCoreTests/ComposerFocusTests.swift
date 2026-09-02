import Testing
@testable import BloomCore

/// The bug: text selected in a browser pane, Cmd+C, and nothing copied, because the composer had
/// already taken the keyboard back. See `ComposerFocus`.
@Suite("The composer's hold on the keyboard")
struct ComposerFocusTests {
    @Test func takesTheKeyboardWhenSomethingElseAsksItTo() {
        #expect(ComposerFocus.shouldTakeKeyboard(
            wantsFocus: true, holdsKeyboard: false, isReportingChange: false
        ))
    }

    /// The gap: the view has resigned, the binding has not caught up, and a redraw lands in
    /// between. This is the one that took the keyboard off the page.
    @Test func leavesItAloneWhileTheViewsOwnResignIsStillInFlight() {
        #expect(!ComposerFocus.shouldTakeKeyboard(
            wantsFocus: true, holdsKeyboard: false, isReportingChange: true
        ))
    }

    @Test func doesNothingWhenItAlreadyHasIt() {
        #expect(!ComposerFocus.shouldTakeKeyboard(
            wantsFocus: true, holdsKeyboard: true, isReportingChange: false
        ))
        #expect(!ComposerFocus.shouldGiveUpKeyboard(wantsFocus: true, holdsKeyboard: true))
    }

    @Test func givesItUpWhenTheBindingSaysSo() {
        #expect(ComposerFocus.shouldGiveUpKeyboard(wantsFocus: false, holdsKeyboard: true))
    }

    @Test func hasNothingToGiveUpWhenItNeverHadIt() {
        #expect(!ComposerFocus.shouldGiveUpKeyboard(wantsFocus: false, holdsKeyboard: false))
    }

    /// The two are never both true, whatever they are handed. A pass that took the keyboard and
    /// gave it up in the same breath would be a composer that fights itself, which is the failure
    /// the deferred write was introduced to avoid in the first place.
    @Test func neverBothAtOnce() {
        for wants in [true, false] {
            for holds in [true, false] {
                for reporting in [true, false] {
                    let takes = ComposerFocus.shouldTakeKeyboard(
                        wantsFocus: wants, holdsKeyboard: holds, isReportingChange: reporting
                    )
                    let gives = ComposerFocus.shouldGiveUpKeyboard(
                        wantsFocus: wants, holdsKeyboard: holds
                    )
                    #expect(!(takes && gives))
                }
            }
        }
    }
}
