import UIKit
import BloomClient

/// The shared split model owns ratios and bounds. This view supplies native drag and
/// accessibility input without recreating the live terminal, browser or conversation panes.
final class WorkspaceSplitDividerView: UIView {
    var onResize: ((Double) -> Void)?
    private var geometry: SplitDividerFrame
    private let rule = UIView()
    private let gripBackground = UIView()
    private let grip = UIView()
    private var dragStart: (ratio: Double, span: Double)?

    init(geometry: SplitDividerFrame) {
        self.geometry = geometry
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        rule.backgroundColor = BloomTheme.border
        gripBackground.backgroundColor = BloomTheme.panel
        gripBackground.layer.cornerRadius = 7
        gripBackground.layer.borderWidth = 1
        gripBackground.layer.borderColor = BloomTheme.border.cgColor
        grip.backgroundColor = BloomTheme.secondary
        grip.layer.cornerRadius = 1.5
        for element in [rule, gripBackground, grip] {
            element.isUserInteractionEnabled = false
            element.accessibilityElementsHidden = true
            addSubview(element)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let reset = UITapGestureRecognizer(target: self, action: #selector(equalise))
        reset.numberOfTapsRequired = 2
        addGestureRecognizer(reset)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Equal Sizes") { [weak self] _ in
            self?.onResize?(0.5)
            return true
        }]
        update(geometry)
    }
    required init?(coder: NSCoder) { fatalError("Use init(geometry:)") }

    func update(_ geometry: SplitDividerFrame) {
        self.geometry = geometry
        let sideBySide = geometry.axis == .horizontal
        frame = sideBySide
            ? CGRect(x: geometry.frame.midX - 22, y: geometry.frame.minY, width: 44, height: geometry.frame.height)
            : CGRect(x: geometry.frame.minX, y: geometry.frame.midY - 22, width: geometry.frame.width, height: 44)
        accessibilityLabel = sideBySide ? "Resize side-by-side panes" : "Resize stacked panes"
        accessibilityValue = "\(sideBySide ? "Left" : "Top") side \(Int((geometry.ratio * 100).rounded())) percent"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if geometry.axis == .horizontal {
            rule.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            gripBackground.frame = CGRect(x: bounds.midX - 7, y: bounds.midY - 20, width: 14, height: 40)
            grip.frame = CGRect(x: bounds.midX - 1.5, y: bounds.midY - 12, width: 3, height: 24)
        } else {
            rule.frame = CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
            gripBackground.frame = CGRect(x: bounds.midX - 20, y: bounds.midY - 7, width: 40, height: 14)
            grip.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 1.5, width: 24, height: 3)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let strip = geometry.axis == .horizontal
            ? CGRect(x: bounds.midX - 10, y: 0, width: 20, height: bounds.height)
            : CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
        let handle = CGRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
        return bounds.contains(point) && (strip.contains(point) || handle.contains(point))
    }

    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            guard geometry.span.isFinite, geometry.span > 0 else { return }
            dragStart = (geometry.ratio, geometry.span)
            grip.backgroundColor = BloomTheme.accent
        }
        if let start = dragStart, [.began, .changed, .ended].contains(recognizer.state) {
            // The divider's own frame moves while dragging, so use the stable parent canvas.
            let translation = recognizer.translation(in: superview)
            let delta = geometry.axis == .horizontal ? translation.x : translation.y
            onResize?(start.ratio + Double(delta) / start.span)
        }
        if [.ended, .cancelled, .failed].contains(recognizer.state) {
            dragStart = nil
            grip.backgroundColor = BloomTheme.secondary
        }
    }

    @objc private func equalise() { onResize?(0.5) }
    override func accessibilityIncrement() { onResize?(geometry.ratio + 0.05) }
    override func accessibilityDecrement() { onResize?(geometry.ratio - 0.05) }
}
