import AppKit
import SwiftUI

/// Gutter keys use scrollToVisible, which does not emit a SwiftUI scroll phase. Release the
/// navigation anchor before input reaches a control, including legacy mouse wheels and editors.
struct ReviewNavigationInput: NSViewRepresentable {
    var armed: Bool
    var onInteraction: () -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.onInteraction = onInteraction
        view.armed = armed
    }

    static func dismantleNSView(_ view: InputView, coordinator: Void) {
        view.armed = false
        view.onInteraction = nil
    }

    final class InputView: NSView {
        var onInteraction: (() -> Void)?
        var armed = false { didSet { updateMonitor() } }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        func handle(_ event: NSEvent) {
            guard armed, let window, event.window === window, let scroll = enclosingScrollView else { return }
            if event.type == .keyDown {
                guard let responder = window.firstResponder as? NSView,
                      responder.isDescendant(of: scroll) else { return }
            } else {
                let point = scroll.convert(event.locationInWindow, from: nil)
                guard scroll.bounds.contains(point) else { return }
            }
            onInteraction?()
        }

        private func updateMonitor() {
            guard armed, window != nil else {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }
    }
}
