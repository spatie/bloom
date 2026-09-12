import UIKit
import BloomClient
@preconcurrency import AppAuth

final class BloomSplitController: UISplitViewController, UISplitViewControllerDelegate {
    private let model: MobileConnection
    init(model: MobileConnection) {
        self.model = model
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        minimumPrimaryColumnWidth = 280
        preferredPrimaryColumnWidth = 300
        maximumPrimaryColumnWidth = 340
        displayModeButtonVisibility = .always
        presentsWithGesture = true
        view.tintColor = BloomTheme.accent
        let projects = ProjectsController(model: model)
        setViewController(BloomTheme.navigation(projects), for: .primary)
        let empty = UIViewController()
        empty.view.backgroundColor = BloomTheme.background
        var content = UIContentUnavailableConfiguration.empty()
        content.text = "Your work, wherever you are"
        content.secondaryText = "Connect to Bloom Server to open a workspace."
        content.image = UIImage(systemName: "leaf")
        empty.contentUnavailableConfiguration = content
        setViewController(BloomTheme.navigation(empty), for: .secondary)
    }

    func splitViewController(_ splitViewController: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        let detail = (viewController(for: .secondary) as? UINavigationController)?.topViewController
        return detail is WorkspaceDeskController || detail is WorkspaceController || detail is ConversationController ? proposedTopColumn : .primary
    }

    @discardableResult
    func openWorkspace(_ workspace: RemoteWorkspace, preferredSessionID: SessionID? = nil) -> WorkspaceDeskController {
        let controller = WorkspaceDeskController(connection: model, workspace: workspace)
        controller.preferredSessionID = preferredSessionID
        (viewController(for: .primary) as? UINavigationController)?.viewControllers.compactMap { $0 as? ProjectsController }.first?.selectWorkspace(workspace.id, reveal: true)
        // Keep workspace width stable while the native sidebar slides over it. A tiled
        // project column otherwise takes space from both the chat and the browser.
        preferredSplitBehavior = .overlay
        preferredDisplayMode = .secondaryOnly
        showDetailViewController(BloomTheme.navigation(controller), sender: self)
        if !isCollapsed { hide(.primary) }
        return controller
    }

    func showWorkspacePicker() {
        preferredSplitBehavior = .tile
        preferredDisplayMode = .oneBesideSecondary
        show(.primary)
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
}

final class ProjectsController: UITableViewController {
    private let model: MobileConnection
    private var displayedAddress: String?
    private var selectedWorkspaceID: WorkspaceID?
    private var headerWidth: CGFloat = 0
    private var projects: [RemoteProject] { model.catalogue?.repositories.filter { !$0.hidden } ?? [] }

    init(model: MobileConnection) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Projects"
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        BloomTheme.list(tableView)
        tableView.sectionHeaderTopPadding = 8
        tableView.estimatedRowHeight = 64
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "server.rack"), primaryAction: UIAction { [weak self] _ in self?.connect() })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.importProject() })
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Server connection"
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Add project"
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { defer { self.refreshControl?.endRefreshing() }; do { try await self.model.refresh() } catch { self.show(error) } }
        }, for: .valueChanged)
        model.changed = { [weak self] in self?.update() }
        update()
    }

    private func update() {
        let currentAddress = model.catalogue == nil ? nil : model.address
        if displayedAddress != currentAddress {
            displayedAddress = currentAddress
            let empty = UIViewController()
            empty.view.backgroundColor = BloomTheme.background
            var content = UIContentUnavailableConfiguration.empty()
            content.text = "Choose a workspace"
            content.secondaryText = "Your agents keep running on Bloom Server."
            empty.contentUnavailableConfiguration = content
            splitViewController?.setViewController(BloomTheme.navigation(empty), for: .secondary)
            (splitViewController as? BloomSplitController)?.showWorkspacePicker()
        }
        tableView.reloadData()
        if let selectedWorkspaceID { selectWorkspace(selectedWorkspaceID, reveal: false) }
        navigationItem.prompt = nil
        updateHeader()
        if projects.isEmpty {
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: model.service == nil ? "leaf" : "folder.badge.plus")
            content.text = model.service == nil ? "Your workspace, anywhere" : "Make room for your next idea"
            content.secondaryText = model.service == nil
                ? "Connect your server and pick up where you left off. Your agents keep working while you're away."
                : "Add a GitHub project to start your first workspace on this server."
            content.button.title = model.service == nil ? "Connect to server" : "Add project"
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self else { return }
                if self.model.service == nil { self.connect() } else { self.importProject() }
            }
            contentUnavailableConfiguration = content
        } else { contentUnavailableConfiguration = nil }
        navigationItem.rightBarButtonItem?.isEnabled = model.canSend
    }

    override func numberOfSections(in tableView: UITableView) -> Int { projects.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { projects[section].name }
    private func workspaces(_ section: Int) -> [RemoteWorkspace] {
        model.catalogue?.workspaces.filter { $0.repoID == projects[section].id } ?? []
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { workspaces(section).count + 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let workspaces = workspaces(indexPath.section)
        if indexPath.row < workspaces.count {
            let workspace = workspaces[indexPath.row]
            let sessions = model.catalogue?.sessions.filter { $0.workspaceID == workspace.id } ?? []
            let busy = sessions.contains { $0.state == "running" }
            let waiting = sessions.contains { $0.state == "waiting" }
            let state = waiting ? "Needs your answer" : busy ? "Agent working" : workspace.branch
            let tint = waiting ? BloomTheme.colour(PaletteInk.warning) : BloomTheme.accent
            let cell = BloomTheme.cell(title: workspace.name, detail: state,
                                       symbol: waiting ? "hand.raised" : busy ? "circle.dotted.circle" : "square.stack.3d.up", tint: tint,
                                       disclosure: traitCollection.horizontalSizeClass == .compact)
            configureRow(cell)
            let original = cell.contentConfiguration as? UIListContentConfiguration
            cell.automaticallyUpdatesContentConfiguration = false
            cell.automaticallyUpdatesBackgroundConfiguration = false
            cell.configurationUpdateHandler = { cell, state in
                guard var content = original?.updated(for: state) else { return }
                // UIKit's focused-row white ink assumes its own selection fill. Our neutral
                // sidebar keeps semantic ink in every state, including hardware-keyboard focus.
                content.textProperties.color = .label
                content.secondaryTextProperties.color = .secondaryLabel
                content.imageProperties.tintColor = tint
                cell.contentConfiguration = content
                var background = UIBackgroundConfiguration.listCell()
                background.backgroundColor = state.isSelected || state.isHighlighted ? .secondarySystemFill : BloomTheme.background
                cell.backgroundConfiguration = background
            }
            cell.setNeedsUpdateConfiguration()
            return cell
        }
        let cell = BloomTheme.cell(title: "New workspace", symbol: "plus", disclosure: false)
        configureRow(cell)
        var content = cell.contentConfiguration as? UIListContentConfiguration
        content?.textProperties.font = .preferredFont(forTextStyle: .body)
        content?.textProperties.color = BloomTheme.accent
        cell.contentConfiguration = content
        return cell
    }

    private func configureRow(_ cell: UITableViewCell) {
        guard var content = cell.contentConfiguration as? UIListContentConfiguration else { return }
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.imageToTextPadding = 10
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        cell.contentConfiguration = content
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if abs(headerWidth - tableView.bounds.width) > 1 { updateHeader() }
    }

    private func updateHeader() {
        headerWidth = tableView.bounds.width
        guard model.catalogue != nil || model.canRetryConnection || model.recovery.phase == .connecting || model.recovery.phase == .reconnecting else { tableView.tableHeaderView = nil; return }
        let host = URL(string: model.address)?.host ?? model.address
        let label = BloomTheme.label(host, style: .subheadline)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        let count = model.catalogue?.workspaces.count ?? 0
        let detail = BloomTheme.label(count == 1 ? "1 workspace" : "\(count) workspaces", style: .footnote, secondary: true)
        let icon = UIImageView(image: UIImage(systemName: "server.rack", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2)))
        icon.tintColor = BloomTheme.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [label, detail]); text.axis = .vertical; text.spacing = 4
        let stack = UIStackView(arrangedSubviews: [icon, text]); stack.spacing = 12; stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        let connectionStatus = MobileConnectionStatusView()
        connectionStatus.update(model.recovery, canRetry: model.canRetryConnection)
        connectionStatus.onRetry = { [weak self] in self?.model.retryConnection() }
        let header = UIStackView(arrangedSubviews: [stack, connectionStatus]); header.axis = .vertical
        header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 76)
        let fitting = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame.size.height = max(76, fitting.height)
        tableView.tableHeaderView = header
    }

    func selectWorkspace(_ id: WorkspaceID, reveal: Bool) {
        selectedWorkspaceID = id
        for section in projects.indices {
            if let row = workspaces(section).firstIndex(where: { $0.id == id }) {
                tableView.selectRow(at: IndexPath(row: row, section: section), animated: false, scrollPosition: reveal ? .top : .none)
                return
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let workspaces = workspaces(indexPath.section)
        if indexPath.row < workspaces.count {
            (splitViewController as? BloomSplitController)?.openWorkspace(workspaces[indexPath.row])
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            createWorkspace(projects[indexPath.section])
        }
    }

    private func connect() {
        let navigation = BloomTheme.navigation(ServerConnectionController(model: model))
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    private func importProject() {
        let picker = GitHubRepositoryPickerController(model: model) { [weak self] project in
            guard let self else { return }
            self.dismiss(animated: true) { self.createWorkspace(project) }
        }
        present(BloomTheme.navigation(picker), animated: true)
    }

    private func createWorkspace(_ project: RemoteProject) {
        let controller = CreateWorkspaceController(model: model, project: project)
        controller.onCreated = { [weak self] created, mode in
            guard let self, let split = self.splitViewController as? BloomSplitController else { return }
            let desk = split.openWorkspace(created.workspace, preferredSessionID: created.session?.id)
            Task { await desk.openInitialMode(mode) }
        }
        present(BloomTheme.navigation(controller), animated: true)
    }

    private func execute(_ command: RemoteCommand, service: RemoteWorkspaceService) {
        Task {
            do { _ = try await service.client.request(command); try await self.model.refresh() } catch {
                self.show(error, retry: { [weak self] in self?.execute(command, service: service) })
            }
        }
    }
}

extension UIViewController {
    func show(_ error: Error, retry: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Could not complete request", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        if !(error is ConnectionRefusal), let retry {
            alert.message = error.localizedDescription + "\nThe server may have completed it. Retry uses the same command ID."
            alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in retry() })
        }
        present(alert, animated: true)
    }
}
