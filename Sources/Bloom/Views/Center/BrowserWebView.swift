import SwiftUI
import AppKit

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

/// The SwiftUI face of a browser tab. It owns nothing: the live view comes from the tab's
/// `BrowserSession`, which is what keeps a page loaded across tab and workspace switches.
struct BrowserWebView: NSViewRepresentable {
    var session: BrowserSession

    func makeNSView(context: Context) -> BrowserHostView {
        let host = BrowserHostView()
        host.attach(session.pageView)
        return host
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        nsView.attach(session.pageView)
    }
}
