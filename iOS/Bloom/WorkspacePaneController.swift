import UIKit

/// System toolbar and containment around shared content, with no custom tab interaction model.
final class WorkspacePaneController: UIViewController {
    private let content: UIViewController
    var embeddedContent: UIViewController { content }
    private var paneTitle: String
    private let image: String
    private var headingLabel: UILabel?
    private let toolbar = UIToolbar()
    private var headingWidth: NSLayoutConstraint?
    private var actionCount = 0
    private let onClose: (() -> Void)?
    init(title: String, image: String, content: UIViewController, onClose: (() -> Void)? = nil) {
        paneTitle = title; self.image = image; self.content = content; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(title:image:content:)") }
    func rename(_ title: String) { paneTitle = title; headingLabel?.text = title }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        toolbar.tintColor = BloomTheme.accent
        let label = BloomTheme.label(paneTitle, style: .subheadline)
        headingLabel = label
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let icon = UIImageView(image: UIImage(systemName: image)); icon.tintColor = BloomTheme.secondary
        icon.accessibilityElementsHidden = true
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [icon, label]); heading.spacing = 8; heading.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headingWidth = heading.widthAnchor.constraint(equalToConstant: 160)
        headingWidth?.isActive = true
        content.loadViewIfNeeded()
        toolbar.items = [UIBarButtonItem(customView: heading), .flexibleSpace()]
        toolbar.items?.append(contentsOf: content.navigationItem.rightBarButtonItems ?? [])
        if let onClose {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in onClose() })
            close.accessibilityLabel = "Close pane"
            toolbar.items?.append(close)
        }
        actionCount = (toolbar.items?.count ?? 2) - 2
        addChild(content)
        let stack = UIStackView(arrangedSubviews: [toolbar, content.view])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
        ])
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Long conversation titles must yield to their native toolbar actions in narrow panes.
        let available = max(44, toolbar.bounds.width - 32 - CGFloat(actionCount) * 44)
        let width = actionCount == 0 ? available : min(available, toolbar.bounds.width * 0.6)
        if headingWidth?.constant != width { headingWidth?.constant = width }
    }
}
