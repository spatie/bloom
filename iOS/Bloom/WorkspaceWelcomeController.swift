import UIKit

/// The iPad's empty detail follows the connection and catalogue, so its next action remains
/// useful after connecting or adding a first project without replacing an open workspace.
final class WorkspaceWelcomeController: UIViewController {
    private let model: MobileConnection
    private let onConnect: () -> Void
    private let onSetup: () -> Void
    private let onAddProject: () -> Void
    private var observation: UUID?

    init(model: MobileConnection, onConnect: @escaping () -> Void,
         onSetup: @escaping () -> Void, onAddProject: @escaping () -> Void) {
        self.model = model
        self.onConnect = onConnect; self.onSetup = onSetup; self.onAddProject = onAddProject
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:onConnect:onSetup:onAddProject:)") }
    deinit {
        let model = model, observation = observation
        Task { @MainActor in if let observation { model.removeObserver(observation) } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        observation = model.observe { [weak self] in self?.update() }
        update()
    }

    private func update() {
        let connecting = model.recovery.phase == .connecting || model.recovery.phase == .reconnecting
        var content = connecting && model.catalogue == nil ? UIContentUnavailableConfiguration.loading() : .empty()
        if connecting && model.catalogue == nil {
            content.text = "Connecting to your server"
            content.secondaryText = "Your projects and conversations will appear here."
        } else if model.catalogue == nil {
            content.image = UIImage(systemName: "laptopcomputer.and.iphone")
            content.text = "Your work travels with you"
            content.secondaryText = "Run agents on your Bloom Server. Pick up conversations, review code and preview your apps from any device."
            content.button.title = "Connect to Server"
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onConnect() }
            content.secondaryButton.title = "Need a Server?"
            content.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in self?.onSetup() }
        } else if model.catalogue?.repositories.contains(where: { !$0.hidden }) != true {
            content.image = UIImage(systemName: "folder.badge.plus")
            content.text = "Add your first project"
            content.secondaryText = "Choose a GitHub repository, then create a workspace to start working with an agent."
            content.button.title = "Add Project"
            content.buttonProperties.isEnabled = model.canSend
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onAddProject() }
        } else {
            content.image = UIImage(systemName: "square.stack.3d.up")
            content.text = "Choose a workspace"
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
            content.secondaryText = "Open a workspace from Projects, or create one to start a new task."
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.button.title = "Show Projects"
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in
                (self?.splitViewController as? BloomSplitController)?.showWorkspacePicker()
            }
        }
        content.imageProperties.tintColor = BloomTheme.accent
        contentUnavailableConfiguration = content
    }
}
