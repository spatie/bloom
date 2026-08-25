import AppKit
import Foundation
import Observation
import WebKit
import BloomCore

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
    /// Where the page is and what it says it is called, as one value.
    ///
    /// The pair rather than two properties, because the strip has to be told about both in one
    /// go: a title and the navigation that brought it arrive in the same update, and a view with
    /// an `onChange` for each has no way to say which runs first. See
    /// `BrowserTabTitle.advance`.
    ///
    /// The title here is never cleared. WebKit sets `title` to nil the moment a new document
    /// commits and fills it in a beat later, so mirroring the property exactly would empty this
    /// between every two pages; holding the last one is what lets the strip keep a name up while
    /// the next page loads. Whether it is still true of where the tab has got to is decided in
    /// `BrowserTabTitle`, against the address beside it.
    private(set) var page = BrowserTabTitle.BrowserPage()

    @ObservationIgnored private let navigation = NavigationObserver()

    /// KVO on everything the toolbar reads, because the navigation delegate does not see every
    /// navigation.
    ///
    /// It started as KVO on `title` alone, since there is no delegate callback for a title:
    /// `didFinish` fires before the title of a page that sets it from script, and a page that
    /// renames itself while you are reading it fires nothing at all.
    ///
    /// **The address needed exactly the same treatment and did not have it, which is the bug.** A
    /// single page app navigates with `history.pushState`, which is a SAME DOCUMENT navigation:
    /// WebKit updates `url` and the back list, and neither `didCommit` nor `didFinish` fires,
    /// because no document was loaded. There is no public delegate callback for one either, and
    /// this was checked rather than assumed: `WKNavigationDelegate` has nothing with "same
    /// document" in its name. So the field sat on `/login` while the reader walked four pages into
    /// an Inertia site, and the tab strip beside it kept up perfectly, because the title was on
    /// KVO and the address was not.
    ///
    /// `canGoBack` and `canGoForward` were stale in the same way and for the same reason: a
    /// `pushState` pushes a back entry without loading anything, so Back was dead on a page you
    /// really could go back from. `isLoading` is watched with them because the header documents it
    /// as KVO compliant alongside the other three and one line is cheaper than the argument about
    /// which callbacks cover it.
    ///
    /// The delegate stays. It is what reports a failure, and having both is two mechanisms
    /// agreeing rather than a duplicate: `refresh` reads the web view and writes what changed.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

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
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                // On the main thread, measured rather than assumed: WebKit posts every one of
                // these from there, which is also the only thread its properties may be read on.
                MainActor.assumeIsolated {
                    self?.adopt(BrowserTabTitle.BrowserPage(title: view.title ?? ""))
                }
            },
            // No `.initial` on these four, unlike the title: the three lines below set the same
            // facts from the address this tab is opening on, and an initial notification would
            // land before them and read an empty web view.
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        // Shown in the address field from the first frame, before anything has been fetched.
        currentURL = BrowserAddress.url(from: url)
        page = BrowserTabTitle.BrowserPage(address: displayAddress)
        load(url)
    }

    /// Points the tab at whatever the user typed. Anything that cannot be read as an address is
    /// ignored rather than handed to a search engine: this field is for the dev server next door,
    /// and shipping a half-typed line off to a third party is not what it is for.
    func load(_ text: String) {
        guard let url = BrowserAddress.url(from: text) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// The pages behind this one, nearest first, as the menu under the Back arrow draws them.
    ///
    /// Read off `WKBackForwardList` on demand rather than mirrored into a property: the list is
    /// not observable, so a stored copy would need a writer on every navigation and would be one
    /// more thing to get out of step with the web view. Every navigation already moves `page` or
    /// `isLoading`, both of which are observed, so the toolbar is rebuilt and asks again.
    var backHistory: [BrowserToolbar.HistoryEntry] {
        BrowserToolbar.backMenu(webView.backForwardList.backList.map(Self.page))
    }

    var forwardHistory: [BrowserToolbar.HistoryEntry] {
        BrowserToolbar.forwardMenu(webView.backForwardList.forwardList.map(Self.page))
    }

    /// Somewhere further back or further forward than one step. The distance is
    /// `BrowserToolbar.HistoryEntry.id`, which is WebKit's own index into this list.
    func go(back distance: Int) {
        guard let item = webView.backForwardList.item(at: distance) else { return }
        webView.go(to: item)
    }

    private static func page(_ item: WKBackForwardListItem) -> BrowserTabTitle.BrowserPage {
        BrowserTabTitle.BrowserPage(address: item.url.absoluteString, title: item.title ?? "")
    }

    func reload() {
        // A dev server that was not up when the tab opened has no page to reload, so an empty
        // view reloads the address instead of reloading nothing.
        if webView.url == nil, let url = currentURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// A picture of the page as it is on screen right now, as PNG.
    ///
    /// **The visible viewport, not the whole page.** `takeSnapshot` with no rect captures what is
    /// in the pane, which is the thing the user is pointing at when they press the button: the
    /// complaint this feature exists for is "this button is misaligned, look", and what makes that
    /// legible is that the picture is what they were looking at, scroll position and all. Capturing
    /// the full page is possible, by giving `snapshotWidth` the document height, and it is worse in
    /// every case that matters here. A page with a sticky header renders it once, halfway down. A
    /// list that virtualises its rows captures the twenty rows that exist. And an infinite scroller
    /// produces a forty megabyte image of a loading spinner. A viewport shot is always exactly what
    /// was on screen, which is the only promise a screenshot button can keep.
    ///
    /// `afterScreenUpdates` is left at its default of true, so a page that has just been scrolled
    /// or has just finished laying out is captured as it settled rather than a frame before.
    ///
    /// PNG rather than the `NSImage` WebKit hands back, because the attachment path takes bytes
    /// and a format, and because PNG is what a screenshot on this machine already is.
    func snapshot() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        // Points, not pixels, so the picture comes out at the retina size the pane is drawn at
        // rather than at half of it. Nil would give the same, but only while the default holds.
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))

        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            throw BrowserSnapshotFailure()
        }
        return png
    }

    func stop() {
        observations = []
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

    /// The page moved, or renamed itself, or both. One door for all three, and the rule is
    /// `BrowserTabTitle.advance`.
    ///
    /// **The title has to be cleared here as well as in the tab.** Measured against a real web
    /// view: loading a page with no `<title>` fires the observation with an empty string, which is
    /// no news rather than no title, so this holds the last name it had. Without the clearing that
    /// `advance` does on a change of host, a session that had been on spatie.be went on offering
    /// "Spatie" from every address after it, and the tab, which had correctly dropped the name on
    /// the navigation, was handed it straight back on the next update.
    private func adopt(_ page: BrowserTabTitle.BrowserPage) {
        let next = BrowserTabTitle.advance(from: self.page, to: page)
        guard next != self.page else { return }
        self.page = next
    }

    fileprivate func refresh() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let url = webView.url { currentURL = url }
        adopt(BrowserTabTitle.BrowserPage(address: displayAddress))
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

/// The page was captured and the bytes could not be made into a PNG, which is the one failure
/// `takeSnapshot` does not report itself.
struct BrowserSnapshotFailure: LocalizedError {
    var errorDescription: String? { "Bloom could not turn this page into an image." }
}
