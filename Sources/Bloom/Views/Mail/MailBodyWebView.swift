import SwiftUI
import WebKit
import BloomCore

/// A message's HTML body, drawn by WebKit from Mailpit's own preview route.
///
/// **Mailpit's `view/<id>.html` rather than the `HTML` field of the message.** The field is the
/// part as it arrived, and an image embedded in the message is a `cid:` reference in it that no web
/// view can follow. Mailpit's preview rewrites those to its part routes, so inline logos load.
///
/// **No JavaScript.** Mail clients run none, so an email that only works with it is an email that
/// is broken for its readers, and the preview should show that rather than hide it. Remote images
/// do load: this is mail the reader's own app just sent, and a template with its images stripped
/// looks broken in a way the real thing is not.
///
/// **A link opens in the default browser**, since Mail is not tied to a workspace. Anything that
/// is not http or https is left alone.
struct MailBodyWebView: NSViewRepresentable {
    var url: URL
    var onLink: @MainActor (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLink: onLink)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Nothing an email sets, a cookie or local storage, outlives the view or reaches the
        // browser tabs' own store.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLink: @MainActor (URL) -> Void
        var loaded: URL?

        init(onLink: @escaping @MainActor (URL) -> Void) {
            self.onLink = onLink
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // The body itself loads, and so does a frame inside it that Mailpit serves, or a blank
            // one. Nothing else may move this view: a form in an email posting from here would put
            // a page from the reader's app where the message was, under headers that no longer
            // describe it. Images are not navigations and never reach this.
            //
            // **A frame from anywhere else is refused**, though JavaScript is off and nothing is
            // stored: an `<iframe>` pointing at the web is a page fetched because an email said
            // so, and mail clients do not load those either, so the preview should not.
            guard let url = navigationAction.request.url else { return .cancel }
            switch navigationAction.navigationType {
            case .linkActivated:
                if BrowserTab.canOpen(url) { onLink(url) }
                return .cancel
            case .other where url == loaded:
                return .allow
            case .other where navigationAction.targetFrame?.isMainFrame == false:
                return url.scheme == "about" || isMailpit(url) ? .allow : .cancel
            default:
                return .cancel
            }
        }

        /// The same scheme, host and port as the body, which is Mailpit.
        private func isMailpit(_ url: URL) -> Bool {
            guard let loaded else { return false }
            return url.scheme == loaded.scheme && url.host() == loaded.host() && url.port == loaded.port
        }
    }
}
