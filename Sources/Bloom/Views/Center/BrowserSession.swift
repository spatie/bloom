import AppKit
import Foundation
import Observation
import WebKit

/// One browser tab's live web view, and everything the address bar needs to know about it.
///
/// The view is owned here for the same reason a shell is owned by `TerminalSessionStore`: SwiftUI
/// rebuilds views whenever anything near them changes, and a rebuilt `WKWebView` is a page that
/// reloads itself, forgets its history and throws away the form you were halfway through.
///
/// It is an ordinary web view and nothing more. There is no message handler, no scheme handler and
/// no injected script, so a page loaded here has exactly the reach any page in Safari would have:
/// none at all into this app, its database, its worktrees or the user's credentials.
@MainActor
@Observable
final class BrowserSession {
    let webView: BrowserPageWebView

    /// What a pane actually puts on screen, which is not the web view itself.
    ///
    /// The Web Inspector attaches by adding its own view to the web view's SUPERVIEW and shrinking
    /// the web view to make room for it. Handing the web view straight to the pane, which is what
    /// this did first, meant that superview was the host SwiftUI had just made, so switching
    /// workspace or splitting the pane left the inspector behind in a host that was then thrown
    /// away: the page sprang back to full size, the inspector was gone from the window, and WebKit
    /// still reported it as open. A wrapper of this session's own is a superview that travels with
    /// the web view, so the two move between panes together.
    let pageView = BrowserHostView()

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// Where the page actually is, which is not what the user has typed into the address field.
    private(set) var currentURL: URL?

    @ObservationIgnored private let navigation = NavigationObserver()

    init(url: String) {
        Self.preferInspectorDocked()
        let configuration = WKWebViewConfiguration()
        Self.enableDeveloperExtras(on: configuration.preferences)
        webView = BrowserPageWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        pageView.attach(webView)
        // A dev server is the whole point of this tab, and one that is still booting answers with
        // a connection refused rather than with a page. Painting the app's own surface behind the
        // page keeps that moment from flashing white in a dark window.
        webView.underPageBackgroundColor = NSColor(Palette.surface)
        navigation.owner = self
        webView.navigationDelegate = navigation
        // Shown in the address field from the first frame, before anything has been fetched.
        currentURL = Self.address(from: url)
        load(url)
    }

    /// Points the tab at whatever the user typed. Anything that cannot be read as an address is
    /// ignored rather than handed to a search engine: this field is for the dev server next door,
    /// and shipping a half-typed line off to a third party is not what it is for.
    func load(_ text: String) {
        guard let url = Self.address(from: text) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        // A dev server that was not up when the tab opened has no page to reload, so an empty
        // view reloads the address instead of reloading nothing.
        if webView.url == nil, let url = currentURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        // The page view rather than the web view, so an attached inspector comes out of the window
        // with the page instead of being left in the wrapper on its own. Releasing this session
        // would get there anyway, WebKit takes an inspector down with the page it is inspecting,
        // but only once the pane drawing it has let go, and a closed tab should not still be
        // showing a console.
        pageView.removeFromSuperview()
    }

    /// What the address field should show for the page that is loaded.
    var displayAddress: String {
        currentURL?.absoluteString ?? ""
    }

    fileprivate func refresh() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let url = webView.url { currentURL = url }
    }

    /// Puts Inspect Element in the page's own context menu, and with it the whole Web Inspector.
    ///
    /// Always on, and there is no setting: this tab exists to look at the dev server running in
    /// the worktree next door, and a dev server that will not paint is a question for the console
    /// or the network list every time. A preference would only be a way to have it switched off on
    /// the day it is wanted.
    ///
    /// **`WKWebView.isInspectable` is not the property this needs, though it reads as though it
    /// is.** It was tried first and measured to change nothing here: with it set and nothing else,
    /// a right click on the page still offers Reload and only Reload. It governs REMOTE
    /// inspection, which is the Develop menu in Safari on this Mac reaching in. The item in the
    /// page's own menu is gated on WebKit's `developerExtrasEnabled` setting, which has no public
    /// spelling, so it is reached by KVC. Measured both ways round on macOS 27: with this setting
    /// and without `isInspectable` the item is there and the inspector opens attached to the
    /// bottom of the page; with `isInspectable` and without this setting it is not.
    ///
    /// Asked before it is set, because KVC for a key that has stopped existing is an exception and
    /// not a nil, and a WebKit that renamed this should cost the tab one menu item rather than
    /// take the app down as the pane opens.
    private static func enableDeveloperExtras(on preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else {
            return
        }
        preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    /// The key WebKit remembers the inspector's last attachment in, and it is WebKit's own: it
    /// writes it into whichever application's defaults the inspected web view belongs to.
    private static let startsAttachedKey =
        "__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached"

    /// Asks for the inspector docked into the pane rather than floating in a window of its own.
    ///
    /// The first version of this shipped believing the inspector opened docked, because in every
    /// harness it was measured in it did. It does not always: WebKit refuses to dock into a view
    /// smaller than 500 points wide, or shorter than 334, and silently opens a window instead.
    /// Bisected on macOS 27: 500 wide docks and 499 does not, 334 tall docks and 333 does not,
    /// which is WebKit's 500 point minimum width and its rule that a docked inspector may take
    /// three quarters of the height and must have 250 points. A browser tab that is one half of a
    /// split centre column is easily under the first of those, which is where the floating window
    /// came from.
    ///
    /// **And WebKit then remembers it.** A detach writes the key above, and so does an open that
    /// was forced to detach because the pane was too small, so one look at the inspector in a
    /// narrow pane makes every later one float, at any size, for good. That is why this writes the
    /// preference rather than reads it: the state it is correcting is already on disk.
    ///
    /// Once per launch, not once per tab, so detaching it on purpose still holds for the rest of
    /// the session. It is set before the first web view exists, because WebKit reads it when the
    /// inspector is created and caches it thereafter.
    ///
    /// There is no API for this. `WKPreferences` has nothing about attachment and `_WKInspector`
    /// offers only `attach`, which is refused at these sizes exactly as opening is, and which
    /// there is no callback to call from: nothing tells the app the reader chose Inspect Element.
    /// So it is the defaults key, which is at least the one WebKit itself reads.
    private static var hasAskedForDockedInspector = false

    private static func preferInspectorDocked() {
        guard !hasAskedForDockedInspector else { return }
        hasAskedForDockedInspector = true
        UserDefaults.standard.set(true, forKey: startsAttachedKey)
    }

    /// Localhost first, because that is what a workspace's dev server is and what the tab opens on.
    /// A bare host gets `http`, since a development server rarely has a certificate, and anything
    /// with no dot and no scheme is not an address at all.
    static func address(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if trimmed.contains("://") { return URL(string: trimmed) }

        let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
            || host.hasPrefix("0.0.0.0") || host.hasSuffix(".localhost")
        guard isLocal || host.contains(".") else { return nil }
        return URL(string: (isLocal ? "http://" : "https://") + trimmed)
    }
}

/// Kept off the session itself because `navigationDelegate` is the sort of reference that outlives
/// what it points at, and a separate object makes the weak link back explicit.
private final class NavigationObserver: NSObject, WKNavigationDelegate {
    weak var owner: BrowserSession?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner?.refresh()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        owner?.refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.refresh()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        owner?.refresh()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        owner?.refresh()
    }
}
