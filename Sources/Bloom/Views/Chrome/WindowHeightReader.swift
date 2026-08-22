import SwiftUI
import AppKit

/// Reports the height of the window this view landed in, and keeps reporting it as the window
/// resizes.
///
/// This exists for the completion menus. Their placement rule needs to know how much room there
/// is UNDER the composer, and SwiftUI's global space only says how far a view is from the top of
/// its window: the distance to the bottom is the window's height minus that, and no geometry
/// reader on the view itself can supply the window's height. A sheet made the difference matter,
/// because a sheet is a window sized exactly to its content and a menu placed by guesswork there
/// is clipped at an edge. So the window is asked directly, by the one kind of view that has a
/// pointer to it.
///
/// The content view's bounds rather than the window's frame, because the composer's own
/// measurements are taken in SwiftUI's global space, which is the content's coordinates and not
/// the chrome's, and the two numbers are subtracted from each other.
struct WindowHeightReader: NSViewRepresentable {
    var onChange: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    @MainActor
    final class ProbeView: NSView {
        var onChange: (@MainActor (CGFloat) -> Void)?

        /// `nonisolated(unsafe)` so `deinit` can take the observer back out. Every touch of it is
        /// on the main thread anyway: AppKit calls `viewDidMoveToWindow` there, and deallocation
        /// of a view in a SwiftUI hierarchy happens there too.
        nonisolated(unsafe) private var observer: NSObjectProtocol?
        private var reported: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            report()
            // The window, not this view: the composer keeps its own size while the window under
            // it is dragged taller, so a change worth reacting to can arrive with no layout pass
            // through here at all.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            guard let height = window?.contentView?.bounds.height, height != reported else { return }
            reported = height
            let onChange = onChange
            // A tick later, because this fires from inside AppKit's view insertion, which is
            // inside SwiftUI's own update, and writing state there is the exact re-entrancy
            // SwiftUI logs about.
            Task { @MainActor in onChange?(height) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
