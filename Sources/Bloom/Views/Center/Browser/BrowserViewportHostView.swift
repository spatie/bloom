import AppKit

/// Magnify the document through AppKit's scroll container. Scaling BrowserHostView's bounds
/// directly leaves WebKit's remote drawing surface clipped to its old visible rectangle. Page
/// zoom paints correctly but rounds CSS dimensions, which can miss a breakpoint by a pixel.
final class BrowserViewportHostView: NSView {
    private let scrollView = NSScrollView()
    var viewportSize: CGSize? {
        didSet { if oldValue != viewportSize { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 1
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    func attach(_ view: NSView) {
        guard scrollView.documentView !== view else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        scrollView.documentView = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let page = scrollView.documentView, bounds.width > 0, bounds.height > 0 else { return }
        scrollView.frame = bounds
        let size = viewportSize ?? bounds.size
        page.frame = CGRect(origin: .zero, size: size)
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        if scrollView.magnification != scale { scrollView.magnification = scale }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        page.layoutSubtreeIfNeeded()
    }
}
