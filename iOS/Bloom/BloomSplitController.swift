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
        minimumPrimaryColumnWidth = 220
        preferredPrimaryColumnWidthFraction = 0.19
        maximumPrimaryColumnWidth = 320
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
        showDetailViewController(BloomTheme.navigation(controller), sender: self)
        return controller
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
}

final class ProjectsController: UITableViewController {
    private let model: MobileConnection
    private var displayedAddress: String?
    private var selectedWorkspaceID: WorkspaceID?
    private var projects: [RemoteProject] { model.catalogue?.repositories.filter { !$0.hidden } ?? [] }

    init(model: MobileConnection) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bloom"
        navigationController?.navigationBar.prefersLargeTitles = true
        BloomTheme.list(tableView)
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
        let currentAddress = model.service == nil ? nil : model.address
        if displayedAddress != currentAddress {
            displayedAddress = currentAddress
            let empty = UIViewController()
            empty.view.backgroundColor = BloomTheme.background
            var content = UIContentUnavailableConfiguration.empty()
            content.text = "Choose a workspace"
            content.secondaryText = "Your agents keep running on Bloom Server."
            empty.contentUnavailableConfiguration = content
            splitViewController?.setViewController(BloomTheme.navigation(empty), for: .secondary)
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
        navigationItem.rightBarButtonItem?.isEnabled = model.service != nil
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
            return BloomTheme.cell(title: workspace.name, detail: state,
                                   symbol: waiting ? "hand.raised" : busy ? "circle.dotted.circle" : "square.stack.3d.up",
                                   tint: waiting ? BloomTheme.colour(PaletteInk.warning) : BloomTheme.accent)
        }
        let cell = BloomTheme.cell(title: "New workspace", symbol: "plus", disclosure: false)
        var content = cell.contentConfiguration as? UIListContentConfiguration
        content?.textProperties.font = .preferredFont(forTextStyle: .body)
        content?.textProperties.color = BloomTheme.accent
        cell.contentConfiguration = content
        return cell
    }

    private func updateHeader() {
        guard model.service != nil else { tableView.tableHeaderView = nil; return }
        let host = URL(string: model.address)?.host ?? model.address
        let label = BloomTheme.label(host, style: .subheadline)
        let detail = BloomTheme.label("Connected · \(model.catalogue?.workspaces.count ?? 0) workspaces", style: .footnote, secondary: true)
        let icon = UIImageView(image: UIImage(systemName: "server.rack", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2)))
        icon.tintColor = BloomTheme.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [label, detail]); text.axis = .vertical; text.spacing = 4
        let stack = UIStackView(arrangedSubviews: [icon, text]); stack.spacing = 14; stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 12, trailing: 24)
        stack.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 76)
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        stack.frame.size.height = max(76, fitting.height)
        tableView.tableHeaderView = stack
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
        present(BloomTheme.navigation(ServerConnectionController(model: model)), animated: true)
    }

    private func importProject() {
        let alert = UIAlertController(title: "Add GitHub project", message: "Bloom Server uses its own GitHub sign-in to clone this repository.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "organisation/repository"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, let service = self.model.service else { return }
            let command = RemoteCommand.call("creation", ["_0": .object(["importGitHub": .object(["_0": .string(name)])])])
            self.execute(command, service: service)
        })
        present(alert, animated: true)
    }

    private func createWorkspace(_ project: RemoteProject) {
        let controller = CreateWorkspaceController(model: model, project: project)
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
