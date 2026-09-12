import UIKit

/// System toolbar and containment around shared content, with no custom tab interaction model.
final class WorkspacePaneController: UIViewController {
    private let content: UIViewController
    var embeddedContent: UIViewController { content }
    private var paneTitle: String
    private let image: String
    private var headingLabel: UILabel?
    private let toolbar = UIToolbar()
    private let header = UIStackView()
    private var actionItems: [UIBarButtonItem] = []
    var showsHeader = true {
        didSet {
            guard showsHeader != oldValue else { return }
            header.isHidden = !showsHeader
            toolbar.items = showsHeader ? actionItems : []
        }
    }
    var onClose: (() -> Void)?
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
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [icon, label]); heading.spacing = 8; heading.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.loadViewIfNeeded()
        actionItems = content.navigationItem.rightBarButtonItems ?? []
        if onClose != nil {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in self?.onClose?() })
            close.accessibilityLabel = "Close pane"
            actionItems.append(close)
        }
        toolbar.items = showsHeader ? actionItems : []
        let actionCount = actionItems.count
        toolbar.isHidden = actionCount == 0
        toolbar.widthAnchor.constraint(equalToConstant: CGFloat(actionCount) * 44 + 16).isActive = true
        header.addArrangedSubview(heading)
        header.addArrangedSubview(toolbar)
        header.alignment = .center
        header.spacing = 8
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 6)
        header.isHidden = !showsHeader
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 44)
        headerHeight.priority = .defaultHigh
        headerHeight.isActive = true
        addChild(content)
        let stack = UIStackView(arrangedSubviews: [header, content.view])
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

}
