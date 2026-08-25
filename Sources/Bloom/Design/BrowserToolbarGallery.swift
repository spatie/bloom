import SwiftUI
import BloomCore

/// The browser pane's toolbar in each state its controls can be in, on one page.
///
/// It exists because the bar is a set of controls whose shape is the thing under review: which
/// arrows can be pressed, whether the third glyph is Reload or Stop, and whether there is anything
/// to share. One pane shows one of those at a time, and no screen in the app puts a page four
/// links deep beside a pane that has never been anywhere.
///
/// Drawn from `BrowserToolbarView` rather than from a browser pane, which is why that view was
/// split out: a pane needs a live `BrowserSession` behind it, and an offscreen render paints
/// SwiftUI's yellow placeholder over the `WKWebView` under it in any case.
///
/// `Bloom --snapshot-gallery <dir> --gallery browser-toolbar`.
struct BrowserToolbarGallery: View {
    /// The width a browser pane sits at in one half of a split centre column, which is the
    /// narrowest the bar normally has to hold its shape at.
    private static let pane: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row(
                "A pane nobody has pointed anywhere",
                "Split open on nothing. Both arrows dead, nothing to reload and nothing to share.",
                BrowserToolbar()
            )
            row(
                "The dev server, just opened",
                "Somewhere to be, so Reload and Share come alive. Still no history either way.",
                BrowserToolbar(page: page("http://localhost:3100/", "Bloom"))
            )
            row(
                "Four links deep",
                "Back can be pressed, and a right click on it offers the pages it would walk past.",
                BrowserToolbar(page: page("http://localhost:3100/settings", "Settings"), canGoBack: true)
            )
            row(
                "Gone back, so there is a page ahead as well",
                "The one state that puts both arrows in the same bar.",
                BrowserToolbar(
                    page: page("http://localhost:3100/", "Bloom"),
                    canGoBack: true,
                    canGoForward: true
                )
            )
            row(
                "Loading",
                "Reload becomes Stop in place, so nothing beside it moves for the second it takes.",
                BrowserToolbar(
                    page: page("https://spatie.be/docs", "Docs"),
                    canGoBack: true,
                    isLoading: true
                )
            )
            row(
                "A screenshot on its way to the composer",
                "The camera goes quiet rather than attaching the same page twice.",
                BrowserToolbar(page: page("http://localhost:3100/", "Bloom"), isCapturing: true)
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func page(_ address: String, _ title: String) -> BrowserTabTitle.BrowserPage {
        BrowserTabTitle.BrowserPage(address: address, title: title)
    }

    private func row(_ title: String, _ note: String, _ toolbar: BrowserToolbar) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Text(note)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            BarRow(toolbar: toolbar)
                .frame(width: Self.pane)
                .overlay(alignment: .bottom) { Hairline() }
        }
    }

    /// One bar, with the state a real pane keeps beside it.
    ///
    /// The address and the focus have to be owned by something, because the field is bound to them
    /// and the ring is drawn off them, so the page holds one small view per row rather than one
    /// `@State` shared by six bars showing six different addresses.
    private struct BarRow: View {
        var toolbar: BrowserToolbar

        @State private var address = ""
        @FocusState private var isFocused: Bool

        var body: some View {
            BrowserToolbarView(
                toolbar: toolbar,
                address: $address,
                addressFocus: $isFocused,
                isRingVisible: false,
                backHistory: toolbar.canGoBack ? Self.history : [],
                forwardHistory: toolbar.canGoForward ? BrowserToolbar.forwardMenu(Self.pages) : []
            )
            .task { address = toolbar.page.address }
        }

        private static let pages = [
            BrowserTabTitle.BrowserPage(address: "http://localhost:3100/", title: "Bloom"),
            BrowserTabTitle.BrowserPage(address: "http://localhost:3100/workspaces", title: "Workspaces"),
        ]

        private static let history = BrowserToolbar.backMenu(pages)
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// It does not need the keys. The one state that would, a focused address field drawing its
    /// ring, is the field `HomeBar` already has a page for, and taking the keyboard off whoever is
    /// at this Mac to photograph a two point border is not a trade worth making.
    static let browserToolbar = Gallery(
        name: "browser-toolbar",
        title: "Browser toolbar",
        size: CGSize(width: 570, height: 640),
        needsFocus: false,
        view: { _ in AnyView(BrowserToolbarGallery()) }
    )
}
