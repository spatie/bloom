import AppKit
import SwiftUI

/// Lets the toolbar item holding this view shrink before the buttons beside it are dropped.
///
/// AppKit never compresses a SwiftUI toolbar item. It asks for the content's ideal width and, when
/// the bar is short, moves whatever no longer fits into the overflow menu. Measured on a title with
/// no width cap: at 800 points Search, New and the inspector toggle went with it. `frame` ranges,
/// `.principal` and dropping the spacer all gave the same answer.
///
/// A low compression resistance plus a minimum width gives the toolbar something to give back, and
/// it then keeps the item's maximum in step with the content on its own. `NSToolbarItem.minSize`
/// and `maxSize` do the same by hand, but they are deprecated and the build refuses warnings.
struct ElasticToolbarItem: NSViewRepresentable {
    let minimumWidth: CGFloat

    func makeNSView(context: Context) -> Probe { Probe(minimumWidth: minimumWidth) }

    func updateNSView(_ view: Probe, context: Context) {
        view.minimumWidth = minimumWidth
        view.scheduleElasticity()
    }

    /// Finds the toolbar item it was drawn into, which SwiftUI gives no handle on, by looking for
    /// the item whose view contains this one.
    final class Probe: NSView {
        var minimumWidth: CGFloat
        private weak var configured: NSView?
        private var minimumConstraint: NSLayoutConstraint?

        init(minimumWidth: CGFloat) {
            self.minimumWidth = minimumWidth
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Never takes a click, so the title's own gestures and the window drag are untouched.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleElasticity()
        }

        /// A turn later, because the toolbar has not attached the item's view when this view
        /// first reaches the window.
        func scheduleElasticity() {
            Task { @MainActor [weak self] in self?.makeItemElastic() }
        }

        private func makeItemElastic() {
            guard let hosting = window?.toolbar?.items
                .first(where: { $0.view.map(isDescendant(of:)) ?? false })?.view else { return }
            if configured === hosting, minimumConstraint?.isActive == true {
                minimumConstraint?.constant = minimumWidth
                return
            }
            minimumConstraint?.isActive = false
            hosting.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let constraint = hosting.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
            constraint.isActive = true
            minimumConstraint = constraint
            configured = hosting
        }
    }
}
