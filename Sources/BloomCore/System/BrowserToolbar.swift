import Foundation

/// What the browser pane's toolbar offers, given what the page under it can do.
///
/// Here rather than in the view for the reason `BrowserAddress` next door is: whether Forward can
/// be pressed, whether there is anything to share, what each control is called and what its
/// tooltip says are all rules, and a rule taken inside a `View` is a rule nothing can test. The
/// view draws what this answers and decides none of it.
///
/// It sits beside `BrowserAddress` and `BrowserTabTitle` rather than in `Presentation/` because
/// those two are the browser's other rules and a reader looking for what the browser decides
/// should find the three of them together.
///
/// ## There is no stock component for any of this
///
/// The question comes back every time somebody looks at Safari beside this pane, so the answer is
/// written where they will be reading. **Every AppKit component that draws browser chrome belongs
/// to an `NSWindow`.** `NSToolbar` is a window's, and with it go `NSToolbarItemGroup`, which is
/// what joins Safari's back and forward arrows, and `NSSearchToolbarItem`, which is its address
/// field; `NSWindowTabGroup` gathers whole windows, and there is no `NSTabBar`. This bar is a pane
/// inside a split inside a tab, so none of them can be reached from here. `NSToolbarDisplayMode`
/// has no `unified` case in the macOS 26 SDK either, whatever memory says.
///
/// So the bar is drawn, out of glass and `Capsule`. Glass was refused here once because it
/// "samples an arbitrary web page", which was never true: the pane stacks this bar above the web
/// view rather than over it, so nothing in the bar ever samples the page. What the shapes sample,
/// and what that costs the ink on them, is written on the view.
public struct BrowserToolbar: Equatable, Sendable {
    /// One button in the bar: what it draws, what it is called, and whether it can be pressed.
    public struct Control: Equatable, Sendable {
        /// The SF Symbol, which is the one every Mac browser uses for this control. Symbol names
        /// live in the core already: see `PaneGlyph`.
        public var symbol: String
        /// The short name, which is what VoiceOver reads and what a menu item would be called.
        public var name: String
        /// The tooltip, which is a sentence rather than the name again. A glyph with no word
        /// beside it is discoverable by hovering it, so the hover has to say something the glyph
        /// does not.
        public var help: String
        public var isEnabled: Bool

        public init(symbol: String, name: String, help: String, isEnabled: Bool) {
            self.symbol = symbol
            self.name = name
            self.help = help
            self.isEnabled = isEnabled
        }
    }

    /// Where the page is and what it says it is called.
    public var page: BrowserTabTitle.BrowserPage
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    /// What WebKit says of the fetch in flight, as `estimatedProgress` reports it.
    public var loadProgress: Double
    /// A screenshot is already on its way to the composer, so the camera goes quiet rather than
    /// attaching the same page twice. See `BrowserTabView.capture`.
    public var isCapturing: Bool

    public init(
        page: BrowserTabTitle.BrowserPage = BrowserTabTitle.BrowserPage(),
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        loadProgress: Double = 0,
        isCapturing: Bool = false
    ) {
        self.page = page
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.loadProgress = loadProgress
        self.isCapturing = isCapturing
    }

    /// How much of the field to fill behind the address, or nil for no fill at all.
    ///
    /// Nil rather than zero at both ends, so the field is a plain field before a load starts and
    /// again the moment it finishes: a bar left sitting at 100 percent reads as still working. A
    /// fetch that has not reported anything yet is nil for the same reason.
    public var progress: Double? {
        guard isLoading, loadProgress > 0, loadProgress < 1 else { return nil }
        return loadProgress
    }

    /// Where the page is, as an address the rest of the app agrees is one. Nil for a pane split
    /// open on nothing, which is the one state where most of this bar has nothing to act on.
    public var destination: URL? {
        BrowserAddress.url(from: page.address)
    }

    // MARK: - The controls

    public var back: Control {
        Control(
            symbol: "chevron.backward",
            name: "Back",
            help: "Show the previous page",
            isEnabled: canGoBack
        )
    }

    public var forward: Control {
        Control(
            symbol: "chevron.forward",
            name: "Forward",
            help: "Show the next page",
            isEnabled: canGoForward
        )
    }

    /// One control in two states rather than two controls beside each other.
    ///
    /// Stop and Reload are never both useful, and a bar that grew a sixth button for the second a
    /// page takes to load would shift everything to the right of it twice per navigation. Every
    /// browser on this platform swaps the glyph in place instead.
    public var reload: Control {
        if isLoading {
            return Control(
                symbol: "xmark",
                name: "Stop",
                help: "Stop loading this page",
                isEnabled: true
            )
        }
        // A pane nobody has pointed anywhere has no page to reload, and a button that does
        // nothing when pressed is worse than one that says so.
        return Control(
            symbol: "arrow.clockwise",
            name: "Reload",
            help: "Reload this page",
            isEnabled: destination != nil
        )
    }

    /// The name is the sentence, here and in the page's own context menu, because this is the one
    /// control in the bar that does something no other browser does and so cannot be guessed from
    /// its glyph.
    public var screenshot: Control {
        Control(
            symbol: "camera",
            name: "Send a Screenshot to the Agent",
            help: "Send a screenshot of this page to the agent",
            isEnabled: destination != nil && !isCapturing
        )
    }

    public var share: Control {
        Control(
            symbol: "square.and.arrow.up",
            name: "Share",
            help: "Share this page",
            isEnabled: shareable != nil
        )
    }

    // MARK: - Sharing

    /// What the system's share sheet is handed, or nil when the pane has not been anywhere yet.
    public struct Shareable: Equatable, Sendable {
        public var url: URL
        /// What the sheet's preview calls it: the page's own title, or the host, or the address.
        public var name: String

        public init(url: URL, name: String) {
            self.url = url
            self.name = name
        }
    }

    /// **The URL alone, with the title carried on it rather than beside it.**
    ///
    /// `NSSharingServicePicker` offers only the services that can handle every item it is given,
    /// and Add to Reading List takes URLs and nothing else, so passing the page's title as a
    /// second item would quietly cut the sheet down to the services that accept a string as well.
    /// The title still belongs on the sheet, which is what names the thing being shared at the top
    /// of it, so it travels as the preview's title on a single item. See `BrowserShareButton`.
    public var shareable: Shareable? {
        guard let url = destination else { return nil }
        return Shareable(
            url: url,
            name: BrowserTabTitle.title(
                page: page.title, address: page.address, fallback: url.absoluteString
            )
        )
    }

    // MARK: - The history behind the arrows

    /// The most of the back or forward list a menu offers.
    ///
    /// A browser holds everything visited since the tab opened, and a menu of two hundred pages is
    /// one you scroll rather than read. Ten is about what Safari shows and comfortably more than
    /// the "I clicked past it" the menu exists for.
    public static let historyLimit = 10

    /// One entry of the back or forward list, as the menu under the arrow draws it.
    public struct HistoryEntry: Equatable, Sendable, Identifiable {
        /// How far from the page on screen, negative back and positive forward, which is exactly
        /// what `WKBackForwardList.item(at:)` is indexed by. It is the identity as well, because
        /// no two entries of one list sit at the same distance.
        public var id: Int
        public var name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The pages behind this one, nearest first, which is the order a back menu is read in.
    ///
    /// - Parameter pages: WebKit's `backList`, which is handed over oldest first.
    public static func backMenu(_ pages: [BrowserTabTitle.BrowserPage]) -> [HistoryEntry] {
        entries(Array(pages.reversed()), distance: { -($0 + 1) })
    }

    /// The pages ahead of this one, nearest first.
    ///
    /// - Parameter pages: WebKit's `forwardList`, which is already handed over nearest first.
    public static func forwardMenu(_ pages: [BrowserTabTitle.BrowserPage]) -> [HistoryEntry] {
        entries(pages, distance: { $0 + 1 })
    }

    /// Named by the same chain the tab strip names a page by, so a page reads the same in the
    /// menu, on the tab and in the share sheet. The tab's own fallback is no use here, since a
    /// history entry is not a tab, so the address stands in for it.
    ///
    /// An entry with nothing to call itself at all is dropped rather than drawn as a blank menu
    /// item. Filtering after the numbering, so the distances still point at the right pages.
    private static func entries(
        _ pages: [BrowserTabTitle.BrowserPage], distance: (Int) -> Int
    ) -> [HistoryEntry] {
        pages
            .prefix(historyLimit)
            .enumerated()
            .map { offset, page in
                HistoryEntry(
                    id: distance(offset),
                    name: BrowserTabTitle.title(
                        page: page.title, address: page.address, fallback: page.address
                    )
                )
            }
            .filter { !$0.name.isEmpty }
    }
}
