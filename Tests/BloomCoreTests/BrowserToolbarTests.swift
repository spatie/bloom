import Testing
@testable import BloomCore

/// What the browser pane's toolbar offers, which used to be five ternaries inside a `View`.
@Suite("Browser toolbar")
struct BrowserToolbarTests {
    private static func toolbar(
        address: String = "http://localhost:3100/",
        title: String = "",
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        isCapturing: Bool = false
    ) -> BrowserToolbar {
        BrowserToolbar(
            page: BrowserTabTitle.BrowserPage(address: address, title: title),
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isLoading: isLoading,
            isCapturing: isCapturing
        )
    }

    // MARK: - Going back and forward

    @Test("The arrows can be pressed exactly when the page has somewhere to go")
    func arrowsFollowTheHistory() {
        let empty = Self.toolbar()
        #expect(!empty.back.isEnabled)
        #expect(!empty.forward.isEnabled)

        let both = Self.toolbar(canGoBack: true, canGoForward: true)
        #expect(both.back.isEnabled)
        #expect(both.forward.isEnabled)
    }

    @Test("The arrows are the glyphs every Mac browser uses")
    func arrowsAreTheNativeGlyphs() {
        let toolbar = Self.toolbar()
        #expect(toolbar.back.symbol == "chevron.backward")
        #expect(toolbar.forward.symbol == "chevron.forward")
    }

    @Test("Every control's tooltip says something its name does not")
    func tooltipsAreNotTheNameAgain() {
        let toolbar = Self.toolbar(canGoBack: true)
        for control in [toolbar.back, toolbar.forward, toolbar.reload, toolbar.share] {
            #expect(control.help != control.name)
            #expect(!control.help.isEmpty)
        }
    }

    // MARK: - Reload and stop

    @Test("Loading turns the one control into Stop")
    func loadingBecomesStop() {
        let loading = Self.toolbar(isLoading: true)
        #expect(loading.reload.name == "Stop")
        #expect(loading.reload.symbol == "xmark")
        #expect(loading.reload.isEnabled)

        let idle = Self.toolbar()
        #expect(idle.reload.name == "Reload")
        #expect(idle.reload.symbol == "arrow.clockwise")
        #expect(idle.reload.isEnabled)
    }

    @Test("A pane nobody has pointed anywhere has nothing to reload")
    func reloadNeedsAPage() {
        #expect(!Self.toolbar(address: "").reload.isEnabled)
    }

    @Test("A pane with no page can still be stopped, because it can still be loading one")
    func stopSurvivesAnEmptyAddress() {
        #expect(Self.toolbar(address: "", isLoading: true).reload.isEnabled)
    }

    // MARK: - The camera

    @Test("The camera goes quiet while a capture is in flight")
    func cameraWaitsForItsCapture() {
        #expect(Self.toolbar().screenshot.isEnabled)
        #expect(!Self.toolbar(isCapturing: true).screenshot.isEnabled)
    }

    // MARK: - Sharing

    @Test("A pane with nowhere to be has nothing to share")
    func nothingToShare() {
        let blank = Self.toolbar(address: "")
        #expect(blank.shareable == nil)
        #expect(!blank.share.isEnabled)
    }

    @Test("What is shared is the page's own address")
    func sharesTheAddress() {
        let toolbar = Self.toolbar(address: "https://spatie.be/docs", title: "Docs")
        #expect(toolbar.share.isEnabled)
        #expect(toolbar.shareable?.url.absoluteString == "https://spatie.be/docs")
    }

    @Test("The sheet's preview is named by the page, then by the host")
    func previewIsNamedByThePage() {
        #expect(
            Self.toolbar(address: "https://spatie.be/docs", title: "Docs").shareable?.name == "Docs"
        )
        #expect(
            Self.toolbar(address: "https://www.spatie.be/docs").shareable?.name == "spatie.be"
        )
    }

    @Test("A typed address is turned into a real one before it is shared")
    func typedAddressesAreResolved() {
        #expect(Self.toolbar(address: "localhost:3100").shareable?.url.scheme == "http")
        #expect(Self.toolbar(address: "spatie.be").shareable?.url.scheme == "https")
    }

    // MARK: - The history behind the arrows

    private static func page(_ address: String, _ title: String = "") -> BrowserTabTitle.BrowserPage {
        BrowserTabTitle.BrowserPage(address: address, title: title)
    }

    @Test("The back menu reads nearest first, whatever order WebKit hands it over in")
    func backMenuIsNearestFirst() {
        let menu = BrowserToolbar.backMenu([
            Self.page("https://a.example/", "Oldest"),
            Self.page("https://b.example/", "Middle"),
            Self.page("https://c.example/", "Nearest"),
        ])
        #expect(menu.map(\.name) == ["Nearest", "Middle", "Oldest"])
        #expect(menu.map(\.id) == [-1, -2, -3])
    }

    @Test("The forward menu is already nearest first and is numbered the other way")
    func forwardMenuIsNumberedForwards() {
        let menu = BrowserToolbar.forwardMenu([
            Self.page("https://a.example/", "Next"),
            Self.page("https://b.example/", "After that"),
        ])
        #expect(menu.map(\.name) == ["Next", "After that"])
        #expect(menu.map(\.id) == [1, 2])
    }

    @Test("A page with no title of its own is named by its host")
    func historyFallsBackToTheHost() {
        let menu = BrowserToolbar.forwardMenu([Self.page("https://www.spatie.be/docs")])
        #expect(menu.map(\.name) == ["spatie.be"])
    }

    @Test("A menu is capped rather than holding everything the tab has visited")
    func historyIsCapped() {
        let pages = (0..<40).map { Self.page("https://example.com/\($0)", "Page \($0)") }
        #expect(BrowserToolbar.backMenu(pages).count == BrowserToolbar.historyLimit)
        #expect(BrowserToolbar.forwardMenu(pages).count == BrowserToolbar.historyLimit)
    }

    @Test("An entry with nothing to call itself is dropped, and the rest keep their distances")
    func namelessEntriesAreDropped() {
        let menu = BrowserToolbar.forwardMenu([
            Self.page("https://a.example/", "First"),
            Self.page(""),
            Self.page("https://c.example/", "Third"),
        ])
        #expect(menu.map(\.name) == ["First", "Third"])
        #expect(menu.map(\.id) == [1, 3])
    }

    @Test("An empty history is an empty menu rather than one blank item")
    func emptyHistoryIsEmpty() {
        #expect(BrowserToolbar.backMenu([]).isEmpty)
        #expect(BrowserToolbar.forwardMenu([]).isEmpty)
    }

    @Test("The fill behind the address is there only while a load is really under way")
    func progressIsOnlyDrawnMidLoad() {
        let page = Self.page("https://example.com/", "Example")
        #expect(BrowserToolbar(page: page, isLoading: true, loadProgress: 0.4).progress == 0.4)
        // Nothing before the first report, and nothing once it is done: a field left at full
        // width reads as still working.
        #expect(BrowserToolbar(page: page, isLoading: true, loadProgress: 0).progress == nil)
        #expect(BrowserToolbar(page: page, isLoading: true, loadProgress: 1).progress == nil)
        #expect(BrowserToolbar(page: page, isLoading: false, loadProgress: 0.4).progress == nil)
    }
}
