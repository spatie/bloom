import AppKit
import SwiftUI

/// Hosts the welcome sequence without feeding SwiftUI's ideal size back into AppKit's constraint
/// pass.
///
/// `NSHostingSizingOptions.preferredContentSize` updates the window while AppKit is resolving the
/// hosting view's safe area. A content change can then invalidate that same constraint pass and
/// recurse. Measuring after layout keeps the content-sized window while making the resize a new
/// main-actor turn rather than part of the pass that requested it.
@MainActor
final class WelcomeHostingController<Content: View>: NSHostingController<Content> {
    private let contentWidth: CGFloat
    private var resizeIsScheduled = false

    init(rootView: Content, contentWidth: CGFloat) {
        self.contentWidth = contentWidth
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleResize()
    }

    /// The size used before the controller has joined a window. It is measured from the same root
    /// view that will be installed, so the first frame and every later frame share one rule.
    func fittingContentSize() -> CGSize {
        measuredContentSize()
    }

    private func scheduleResize() {
        guard !resizeIsScheduled else { return }
        resizeIsScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resizeIsScheduled = false
            self.resizeWindow()
        }
    }

    private func resizeWindow() {
        guard let window = view.window else { return }
        let size = measuredContentSize()
        let current = view.bounds.size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5
        else { return }

        let oldFrame = window.frame
        var newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        newFrame.origin.x = oldFrame.origin.x
        newFrame.origin.y = oldFrame.maxY - newFrame.height
        window.setFrame(newFrame, display: true)
    }

    private func measuredContentSize() -> CGSize {
        let proposed = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        let measured = sizeThatFits(in: proposed)
        guard measured.height.isFinite, measured.height > 0 else {
            return CGSize(width: contentWidth, height: max(1, view.bounds.height))
        }
        return CGSize(width: contentWidth, height: ceil(measured.height))
    }
}
