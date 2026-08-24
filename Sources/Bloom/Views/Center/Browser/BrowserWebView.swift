import SwiftUI
import AppKit
import WebKit

/// A plain container so SwiftUI can attach and detach a long-lived view without that view ever
/// being deallocated, and so the page follows the pane size on every layout pass.
///
/// Used twice over: once by SwiftUI, for the pane, and once by `BrowserSession`, as the wrapper
/// the web view lives in so an attached inspector has a superview that outlives the pane. It takes
/// any `NSView` for that reason.
final class BrowserHostView: NSView {
    private weak var page: NSView?

    func attach(_ view: NSView) {
        guard page !== view || view.superview !== self else { return }
        page?.removeFromSuperview()
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        page = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        page?.frame = bounds
    }
}

/// The page itself, and the one thing it does beyond being a `WKWebView`: it puts the pane's own
/// menu on the end of the page's contextual menu.
///
/// Every other pane in the centre column gets `CenterPaneMenu` from SwiftUI's `.contextMenu` on
/// `CenterPaneView`. A browser pane never did, for the reason a terminal pane never did: the right
/// click is taken by an `NSView` and SwiftUI is not offered it. So a browser was the one pane you
/// could not split from, and right clicking it gave WebKit's Reload and Inspect Element where every
/// other pane gave Split Right, Split Down and Close Pane.
///
/// `willOpenMenu` is the hook, and it has to be that one. WebKit builds the page's menu in its web
/// process and hands it over for presentation, so `menu(for:)` is never asked and by the time the
/// menu begins tracking it has been passed to the out of process menu service and holds a single
/// hidden placeholder rather than its rows. `willOpenMenu` is called in between, with the real
/// items still in it: Reload and Inspect Element on the page, Open Link and Copy Link on a link,
/// Copy Image and Download Image on an image. All of them are kept and ours go underneath, because
/// the page's own menu is worth having and Inspect Element was deliberately added to it.
///
/// The items are the very ones `CenterPaneMenu` describes, moved out of an `NSHostingMenu` rather
/// than built again here, so there is one description of what a pane's menu offers and a browser
/// cannot drift away from the rest of the column. The hosting menu is held for as long as the
/// items are, because it is what answers them.
///
/// One thing does not survive the move: the glyphs. An item merged into WebKit's menu is drawn
/// without its image, whether the image was set by SwiftUI or by hand with
/// `NSImage(systemSymbolName:)`, so this menu is the same items as everywhere else without their
/// symbols. Measured on macOS 27, both ways. WebKit's own Share item keeps its icon, so it is the
/// merge and not the menu.
final class BrowserPageWebView: WKWebView {
    /// Built fresh each time, because whether Close Pane is offered depends on how the column is
    /// split at the moment of the click.
    var paneMenu: (@MainActor () -> NSMenu)?

    /// `NSMenuItem` does not own what answers it, so the menu the items came out of is kept until
    /// the next right click replaces it. Letting it go at the end of `willOpenMenu` leaves a menu
    /// of rows that draw and do nothing.
    private var hostedPaneMenu: NSMenu?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let paneMenu else { return }

        let hosted = paneMenu()
        hostedPaneMenu = hosted
        guard !hosted.items.isEmpty else { return }

        menu.addItem(.separator())
        // Out of one menu and into the other: an `NSMenuItem` belongs to a single menu, and adding
        // one that still has a supermenu raises rather than moves it.
        for item in hosted.items {
            hosted.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// The SwiftUI face of a browser tab. It owns nothing: the live view comes from the tab's
/// `BrowserSession`, which is what keeps a page loaded across tab and workspace switches.
struct BrowserWebView: NSViewRepresentable {
    var session: BrowserSession
    /// The pane's own menu, to go under the page's. Set on every update rather than once, because
    /// the tab can be dragged into another pane and the menu belongs to the pane, not the tab.
    var paneMenu: (@MainActor () -> NSMenu)?

    func makeNSView(context: Context) -> BrowserHostView {
        let host = BrowserHostView()
        host.attach(session.pageView)
        session.webView.paneMenu = paneMenu
        return host
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        nsView.attach(session.pageView)
        session.webView.paneMenu = paneMenu
    }
}
