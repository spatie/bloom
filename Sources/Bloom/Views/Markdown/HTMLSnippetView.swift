import SwiftUI
import WebKit

/// An HTML fence drawn by WebKit, its own `<style>` included. No page JavaScript and nothing
/// stored, for `MailBodyWebView`'s reasons: the markup is whatever the agent wrote or quoted.
struct HTMLSnippetView: View {
    private static let minimumHeight: CGFloat = 40
    /// Beyond this the page scrolls inside the fence rather than pushing the transcript away.
    private static let maximumHeight: CGFloat = 600

    let html: String
    /// Called once the page has loaded and measured itself.
    var onReady: () -> Void = {}
    @State private var contentHeight = Self.minimumHeight
    @Environment(\.transcriptEntryID) private var entryID
    @Environment(\.transcriptTable) private var table

    var body: some View {
        HTMLSnippetWebView(html: html) { height in
            // The page measures itself after the click, so the row is held again for that change.
            if let entryID { table?.willResize(entryID) }
            contentHeight = height
            onReady()
        }
            .frame(height: min(max(contentHeight, Self.minimumHeight), Self.maximumHeight))
    }
}

private struct HTMLSnippetWebView: NSViewRepresentable {
    let html: String
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        var onHeight: (CGFloat) -> Void = { _ in }

        /// The snippet itself and its own anchors load; a link goes to the default browser and
        /// nothing else may replace the page.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.scheme == "about" { return .allow }
            if navigationAction.navigationType == .linkActivated, BrowserTab.canOpen(url) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        // ponytail: measured once per load, so a fence resized later keeps its first height.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                // Nought on a failed measure still reports, so the fence never waits on the code for ever.
                self?.onHeight(value as? Double ?? 0)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onHeight(0)
        }
    }
}
