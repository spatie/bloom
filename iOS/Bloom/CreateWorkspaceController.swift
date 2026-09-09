import UIKit
import BloomClient

final class CreateWorkspaceController: UIViewController {
    private let model: MobileConnection
    private let project: RemoteProject
    private let name = UITextField()
    private let prompt = UITextView()
    private var pending: RemoteCommand?
    private var isSubmitting = false

    init(model: MobileConnection, project: RemoteProject) {
        self.model = model; self.project = project
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:project:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New workspace"
        view.backgroundColor = BloomTheme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", primaryAction: UIAction { [weak self] _ in self?.create() })
        let projectLabel = UILabel()
        projectLabel.text = project.name
        projectLabel.textColor = BloomTheme.accent
        projectLabel.adjustsFontForContentSizeCategory = true
        projectLabel.font = .preferredFont(forTextStyle: .headline)
        name.placeholder = "Workspace name"
        name.borderStyle = .roundedRect
        name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true
        name.backgroundColor = BloomTheme.panel
        name.accessibilityLabel = "Workspace name"
        prompt.font = .preferredFont(forTextStyle: .body)
        prompt.adjustsFontForContentSizeCategory = true
        prompt.backgroundColor = BloomTheme.panel
        prompt.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        prompt.layer.cornerRadius = 12
        prompt.accessibilityLabel = "Prompt"
        let label = UILabel()
        label.text = "What would you like to work on?"
        label.font = .preferredFont(forTextStyle: .title2)
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        let note = UILabel()
        note.text = "Bloom creates a branch, prepares the workspace and starts your agent on the server. You can leave the prompt blank to explore first."
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = BloomTheme.secondary
        note.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [projectLabel, name, label, prompt, note])
        stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -20),
            name.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func create() {
        guard !isSubmitting, let service = model.service else { return }
        isSubmitting = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        name.isEnabled = false; prompt.isEditable = false
        Task {
            defer { self.isSubmitting = false; self.navigationItem.rightBarButtonItem?.isEnabled = true }
            do {
                let command: RemoteCommand
                if let pending = self.pending { command = pending } else {
                    command = try await service.workspaceCommand(project: self.project, name: self.name.text ?? "", prompt: self.prompt.text)
                    self.pending = command
                }
                _ = try await service.client.request(command)
                try await self.model.refresh()
                self.dismiss(animated: true)
            } catch {
                        if self.pending == nil { self.name.isEnabled = true; self.prompt.isEditable = true }
                self.navigationItem.rightBarButtonItem?.title = self.pending == nil ? "Create" : "Retry"
                self.show(error)
            }
        }
    }
}
