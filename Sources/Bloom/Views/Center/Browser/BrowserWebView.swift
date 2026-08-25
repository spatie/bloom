import SwiftUI
import AppKit
import WebKit
import BloomCore

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

    /// Where a find key press goes. Set by `BrowserSession`, which owns both this view and the
    /// state the bar is drawn from.
    var findCommand: (@MainActor (BrowserFindCommand) -> Void)?

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

    // MARK: - Find in page

    /// The Edit menu's Find items, which arrive here down the responder chain when the page holds
    /// the keyboard.
    ///
    /// **This is the route that costs nothing and survives.** The conventional Find submenu sends
    /// `performFindPanelAction:` to the first responder, which is what `NSTextView` and SwiftTerm
    /// both already answer, so a browser pane that answers it too is found by that menu the day it
    /// is added without either half knowing about the other. `performKeyEquivalent` below is the
    /// same thing for today, for as long as there is no such menu.
    ///
    /// Not an `override`: `performFindPanelAction` is declared on `NSTextView` rather than on
    /// `NSResponder`, so there is nothing here to override and the selector is reached by the
    /// responder chain's own dispatch.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag),
              let command = Self.command(for: action) else { return }
        findCommand?(command)
    }

    /// `Cmd F`, `Cmd G` and `Shift Cmd G`, and only while this page holds the keyboard.
    ///
    /// **The focus test is the whole of what makes this safe to add.** A key equivalent claimed by
    /// a view claims it for the window: a browser pane merely being on screen while the reader
    /// types in the composer must not take `Cmd F` off the transcript, which is exactly the bug
    /// the review records `Cmd W` having (it closes a chat session in some other pane from a
    /// browser tab). So the event is only read when the first responder is this view or something
    /// inside it, which for a page with focus is WebKit's own content view.
    ///
    /// Everything else falls straight through to `super`, and from there to the menu bar, which is
    /// entitled to it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let command = findKey(event) else { return super.performKeyEquivalent(with: event) }
        findCommand?(command)
        return true
    }

    private func findKey(_ event: NSEvent) -> BrowserFindCommand? {
        guard findCommand != nil, holdsKeyboard else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Option and Control are somebody else's business, and a pane that read past them would
        // answer `Ctrl Cmd G` as Find Previous.
        guard !flags.contains(.option), !flags.contains(.control) else { return nil }
        return BrowserFindCommand.forKey(
            event.charactersIgnoringModifiers ?? "",
            hasCommand: flags.contains(.command),
            hasShift: flags.contains(.shift)
        )
    }

    /// Whether the keys are coming to this page. WebKit's first responder is a content view of its
    /// own inside this one rather than this one, so the test is descent and not identity.
    private var holdsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Which of the standard find actions a browser pane has an answer for. Replace and its
    /// friends are not among them: there is nothing here to write into.
    private static func command(for action: NSTextFinder.Action) -> BrowserFindCommand? {
        switch action {
        case .showFindInterface: .show
        case .nextMatch: .next
        case .previousMatch: .previous
        case .hideFindInterface: .hide
        default: nil
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
    /// What the page can ask the window for, handed down for the same reason and on the same
    /// schedule as the menu above. See `BrowserPaneHost`.
    var host = BrowserPaneHost()

    func makeNSView(context: Context) -> BrowserHostView {
        let view = BrowserHostView()
        view.attach(session.pageView)
        wire()
        return view
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        nsView.attach(session.pageView)
        wire()
    }

    private func wire() {
        session.webView.paneMenu = paneMenu
        session.host = host
    }
}
