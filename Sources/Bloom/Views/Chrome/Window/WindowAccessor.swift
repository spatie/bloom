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

        /// The last window the binding was told about.
        ///
        /// Without it this spins the CPU at 100%: `updateNSView` reports unconditionally, the
        /// report writes SwiftUI state, that state write schedules another update, and the update
        /// reports again. The window itself changes at most twice in the life of the app, so the
        /// only honest thing to send is a change.
        private weak var reported: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindow()
        }

        func reportWindow() {
            guard reported !== window else { return }
            reported = window
            onWindowChange?(window)
        }
    }
}
