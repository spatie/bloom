import SwiftUI
import AppKit
import WebKit

/// A plain container so SwiftUI can attach and detach a long-lived web view without the web view
/// ever being deallocated, and so the page follows the pane size on every layout pass.
final class BrowserHostView: NSView {
    private weak var page: WKWebView?

    func attach(_ view: WKWebView) {
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

/// The SwiftUI face of a browser tab. It owns nothing: the live view comes from the tab's
/// `BrowserSession`, which is what keeps a page loaded across tab and workspace switches.
struct BrowserWebView: NSViewRepresentable {
    var session: BrowserSession

    func makeNSView(context: Context) -> BrowserHostView {
        let host = BrowserHostView()
        host.attach(session.webView)
        return host
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        nsView.attach(session.webView)
    }
}
