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
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", primaryAction: UIAction { [weak self] _ in self?.create() })
        let projectLabel = UILabel()
        projectLabel.text = project.name
        projectLabel.font = .preferredFont(forTextStyle: .headline)
        name.placeholder = "Workspace name"
        name.borderStyle = .roundedRect
        name.accessibilityLabel = "Workspace name"
        prompt.font = .preferredFont(forTextStyle: .body)
        prompt.adjustsFontForContentSizeCategory = true
        prompt.backgroundColor = .secondarySystemBackground
        prompt.layer.cornerRadius = 12
        prompt.accessibilityLabel = "Prompt"
        let label = UILabel()
        label.text = "What would you like to work on?"
        label.font = .preferredFont(forTextStyle: .body)
        let note = UILabel()
        note.text = "Uses this project's server defaults and runs its setup script."
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [projectLabel, name, label, prompt, note])
        stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -20),
            name.heightAnchor.constraint(equalToConstant: 44),
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
                if error is ConnectionRefusal { self.pending = nil }
                if self.pending == nil { self.name.isEnabled = true; self.prompt.isEditable = true }
                self.navigationItem.rightBarButtonItem?.title = self.pending == nil ? "Create" : "Retry"
                self.show(error)
            }
        }
    }
}
