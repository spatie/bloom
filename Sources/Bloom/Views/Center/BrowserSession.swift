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
    let webView: WKWebView

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// Where the page actually is, which is not what the user has typed into the address field.
    private(set) var currentURL: URL?

    @ObservationIgnored private let navigation = NavigationObserver()

    init(url: String) {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
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
