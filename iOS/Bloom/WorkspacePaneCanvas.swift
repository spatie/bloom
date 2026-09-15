import UIKit

/// Nested stack views can finish sizing after their controller's layout callback. Lay out
/// frame-based pane content when the canvas itself has its final bounds.
final class WorkspacePaneCanvas: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
