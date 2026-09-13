import UIKit
import BloomClient

/// A quiet, persistent native notice keeps connection recovery separate from retrying a message.
final class MobileConnectionStatusView: UIView {
    private let title = UILabel()
    private let detail = UILabel()
    private let symbol = UIImageView()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private let content = UIStackView()
    private var measuredWidth: CGFloat = 0
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BloomTheme.panel
        tintColor = BloomTheme.accent
        setContentHuggingPriority(.required, for: .vertical)
        title.font = .preferredFont(forTextStyle: .footnote)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        symbol.image = UIImage(systemName: "wifi.exclamationmark")
        symbol.tintColor = BloomTheme.colour(PaletteInk.warning)
        symbol.contentMode = .scaleAspectFit
        symbol.isAccessibilityElement = false
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Retry"
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 5
        configuration.buttonSize = .small
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6)
        retry.configuration = configuration
        retry.accessibilityLabel = "Retry server connection"
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        retry.setContentHuggingPriority(.required, for: .horizontal)
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        let text = UIStackView(arrangedSubviews: [title, detail]); text.axis = .vertical; text.spacing = 2

        let icon = UIStackView(arrangedSubviews: [symbol, progress]); icon.axis = .vertical
        [icon, text, retry].forEach { content.addArrangedSubview($0) }
        content.alignment = .center; content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let bottom = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8), bottom,
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            symbol.widthAnchor.constraint(equalToConstant: 22),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let symbolHeight = symbol.heightAnchor.constraint(equalToConstant: 22)
        // The icon stack hides the symbol while showing connection progress.
        symbolHeight.priority = .defaultHigh
        symbolHeight.isActive = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MobileConnectionStatusView, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize()
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 28 else { return CGSize(width: UIView.noIntrinsicMetric, height: 60) }
        let fitted = content.systemLayoutSizeFitting(CGSize(width: bounds.width - 28, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height) + 16)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(measuredWidth - bounds.width) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    func update(_ recovery: RemoteConnectionRecovery, canRetry: Bool) {
        title.text = recovery.title
        detail.text = recovery.detail
        retry.isEnabled = canRetry
        retry.isHidden = recovery.phase == .suspended
        let connecting = recovery.phase == .connecting || recovery.phase == .reconnecting
        symbol.isHidden = connecting
        progress.isHidden = !connecting
        if connecting { progress.startAnimating() } else { progress.stopAnimating() }
        accessibilityLabel = recovery.title + ". " + recovery.detail
        isHidden = recovery.phase == .connected
        invalidateIntrinsicContentSize()
    }
}
