import Testing
@testable import BloomCore

/// How narrow the window may be, and what opening the inspector costs it.
///
/// The window's minimum used to be a constant that assumed three panes while two were showing, and
/// making it conditional is only safe if opening the inspector can never ask for more room than
/// the window can be given. `openingTheInspectorCannotClip` is that, written down.
@Suite struct WindowWidthsTests {
    /// Bloom's own numbers, which is the case every other one is a variation of.
    private let widths = WindowWidths(
        sidebar: 420, sidebarMinimum: 200, detail: 420, inspector: 280, divider: 1
    )

    @Test func theWindowGivesBackTheInspectorsRoomWhenItIsNotShowing() {
        #expect(widths.minimum(withInspector: true) == 1122)
        #expect(widths.minimum(withInspector: false) == 841)
    }

    @Test func openingTheInspectorCannotClip() {
        // The case that bit last time. Whatever the collapsed minimum is, adding the inspector and
        // its divider has to land exactly on the presented one: a presented minimum that asked for
        // more than that would be a window the split view overflows the moment the pane arrives.
        //
        // One line each, and that is not a style choice. A `#expect` whose operator starts a
        // continuation line reported `1122.0 == 1122.0` as a failure on CI: swift-testing folds the
        // operators of a broken `SequenceExpr` itself to find the one to split on, and it split
        // this on the wrong one. Both sides printed the same number in the failure message, which
        // is the tell. Keep a comparison on one line here.
        let inspectorAndItsDivider = widths.inspector + widths.divider
        #expect(widths.minimum(withInspector: false) + inspectorAndItsDivider == widths.minimum(withInspector: true))
        #expect(widths.detailHalf(withInspector: false) + inspectorAndItsDivider == widths.detailHalf(withInspector: true))
    }

    @Test func theDetailHalfIsTheWindowMinimumLessTheSidebarAndItsDivider() {
        for showing in [true, false] {
            let half = widths.minimum(withInspector: showing) - widths.sidebar - widths.divider
            #expect(half == widths.detailHalf(withInspector: showing))
        }
    }

    // MARK: - What opening it costs

    @Test func aWindowAlreadyWideEnoughIsLeftAlone() {
        #expect(widths.presenting(windowWidth: 1122, screenWidth: 1800).isSettled)
        #expect(widths.presenting(windowWidth: 1500, screenWidth: 1800).isSettled)
    }

    @Test func aNarrowWindowOnARoomyScreenIsWidenedAndNothingElseMoves() {
        let fit = widths.presenting(windowWidth: 841, screenWidth: 1800)
        #expect(fit.windowWidth == 1122)
        #expect(fit.sidebarWidth == nil)
        #expect(!fit.foldsSidebar)
    }

    @Test func aScreenThatCannotAffordItGrowsTheWindowAsFarAsItGoesAndTheSidebarGivesTheRest() {
        // 1024 points is a small external display. The window takes the screen, and the sidebar
        // comes down from its 420 reserve to what is left: 1024 less a divider and the detail half.
        let fit = widths.presenting(windowWidth: 900, screenWidth: 1024)
        #expect(fit.windowWidth == 1024)
        #expect(fit.sidebarWidth == 322)
        #expect(!fit.foldsSidebar)
    }

    @Test func aWindowAtTheScreensWidthAlreadyOnlyMovesTheSidebar() {
        // The question this was written to answer: the window cannot grow, so the sidebar is what
        // gives, and it is the only one of the three whose content survives being narrow.
        let fit = widths.presenting(windowWidth: 1024, screenWidth: 1024)
        #expect(fit.windowWidth == nil)
        #expect(fit.sidebarWidth == 322)
        #expect(!fit.foldsSidebar)
    }

    @Test func aScreenTooNarrowEvenForTheSidebarsMinimumFoldsItAway() {
        // A Sidecar iPad in portrait is 768 points. 768 less a divider and 701 leaves 66, and 66
        // points of workspace rows is not a sidebar.
        let fit = widths.presenting(windowWidth: 768, screenWidth: 768)
        #expect(fit.foldsSidebar)
        #expect(fit.sidebarWidth == nil)
    }

    @Test func aWindowWiderThanItsScreenIsNeverShrunk() {
        // Dragged half off the display, which is the user's business and not the inspector's.
        let fit = widths.presenting(windowWidth: 1100, screenWidth: 1000)
        #expect(fit.windowWidth == nil)
        #expect(fit.sidebarWidth == 398)
    }

    @Test func whatIsAskedForIsAlwaysSomethingTheWindowCanBeGiven() {
        // The property behind every case above: after presenting, the panes at their minimums plus
        // the sidebar it is left with never exceed the width the window ends up at.
        for window in stride(from: 600.0, through: 2000, by: 37) {
            for screen in [768.0, 1024, 1280, 1440, 1800, 3008] {
                let fit = widths.presenting(windowWidth: window, screenWidth: screen)
                let settled = fit.windowWidth ?? window
                #expect(settled >= window)
                let sidebar = fit.foldsSidebar ? 0 : (fit.sidebarWidth ?? widths.sidebar)
                #expect(sidebar + widths.divider + widths.detailHalf(withInspector: true) <= settled)
            }
        }
    }

    // MARK: - The sidebar's own ceiling

    @Test func theSidebarKeepsItsReserveOnAnyScreenThatCanAffordIt() {
        #expect(widths.sidebarMaximum(sharing: 1122, withInspector: true) == 420)
        #expect(widths.sidebarMaximum(sharing: 3008, withInspector: true) == 420)
        // And with the inspector away there is 281 points more of it to go round.
        #expect(widths.sidebarMaximum(sharing: 841, withInspector: false) == 420)
    }

    @Test func theSidebarsCeilingComesDownBeforeItFolds() {
        #expect(widths.sidebarMaximum(sharing: 1024, withInspector: true) == 322)
        #expect(widths.sidebarMaximum(sharing: 902, withInspector: true) == 200)
        #expect(widths.sidebarMaximum(sharing: 901, withInspector: true) == nil)
    }
}
