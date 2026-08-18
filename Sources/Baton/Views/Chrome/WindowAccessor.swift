import AppKit
import SwiftUI

/// Exposes the hosting window for title-bar customization that SwiftUI does not model directly.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowReadingView {
        let view = WindowReadingView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowReadingView, context: Context) {
        nsView.onWindowChange = { window = $0 }
        nsView.reportWindow()
    }

    /// Reports attachment changes because a representable is created before its window exists.
    final class WindowReadingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindow()
        }

        func reportWindow() {
            onWindowChange?(window)
        }
    }
}
