import UIKit

/// System toolbar and containment around shared content, with no custom tab interaction model.
final class WorkspacePaneController: UIViewController {
    private let content: UIViewController
    private let paneTitle: String
    private let image: String
    private let onClose: (() -> Void)?
    init(title: String, image: String, content: UIViewController, onClose: (() -> Void)? = nil) {
        paneTitle = title; self.image = image; self.content = content; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(title:image:content:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        let toolbar = UIToolbar()
        toolbar.tintColor = BloomTheme.accent
        let label = BloomTheme.label(paneTitle, style: .subheadline)
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let icon = UIImageView(image: UIImage(systemName: image)); icon.tintColor = BloomTheme.secondary
        let heading = UIStackView(arrangedSubviews: [icon, label]); heading.spacing = 8; heading.alignment = .center
        content.loadViewIfNeeded()
        toolbar.items = [UIBarButtonItem(customView: heading), .flexibleSpace()]
        toolbar.items?.append(contentsOf: content.navigationItem.rightBarButtonItems ?? [])
        if let onClose {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in onClose() })
            close.accessibilityLabel = "Close pane"
            toolbar.items?.append(close)
        }
        addChild(content)
        let stack = UIStackView(arrangedSubviews: [toolbar, content.view])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 50),
        ])
        content.didMove(toParent: self)
    }
}
