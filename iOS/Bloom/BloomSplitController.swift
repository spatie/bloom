import UIKit
import BloomClient
@preconcurrency import AppAuth

final class BloomSplitController: UISplitViewController {
    init(model: MobileConnection) {
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        let projects = ProjectsController(model: model)
        setViewController(UINavigationController(rootViewController: projects), for: .primary)
        let empty = UIViewController()
        empty.view.backgroundColor = .systemBackground
        var content = UIContentUnavailableConfiguration.empty()
        content.text = "Your work, wherever you are"
        content.secondaryText = "Connect to Bloom Server to open a workspace."
        content.image = UIImage(systemName: "leaf")
        empty.contentUnavailableConfiguration = content
        setViewController(UINavigationController(rootViewController: empty), for: .secondary)
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
}

final class ProjectsController: UITableViewController {
    private let model: MobileConnection
    private var displayedAddress: String?
    private var projects: [RemoteProject] { model.catalogue?.repositories.filter { !$0.hidden } ?? [] }

    init(model: MobileConnection) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bloom"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Server", primaryAction: UIAction { [weak self] _ in self?.connect() })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.importProject() })
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
            empty.view.backgroundColor = .systemBackground
            var content = UIContentUnavailableConfiguration.empty()
            content.text = "Choose a workspace"
            content.secondaryText = "Your agents keep running on Bloom Server."
            empty.contentUnavailableConfiguration = content
            splitViewController?.setViewController(UINavigationController(rootViewController: empty), for: .secondary)
        }
        tableView.reloadData()
        navigationItem.prompt = model.service == nil ? "Connect to Bloom Server" : URL(string: model.address)?.host
        navigationItem.rightBarButtonItem?.isEnabled = model.service != nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int { projects.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { projects[section].name }
    private func workspaces(_ section: Int) -> [RemoteWorkspace] {
        model.catalogue?.workspaces.filter { $0.repoID == projects[section].id } ?? []
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { workspaces(section).count + 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let workspaces = workspaces(indexPath.section)
        if indexPath.row < workspaces.count {
            let workspace = workspaces[indexPath.row]
            cell.textLabel?.text = workspace.name
            cell.detailTextLabel?.text = workspace.branch
            cell.imageView?.image = UIImage(systemName: "folder")
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.textLabel?.text = "New workspace"
            cell.textLabel?.textColor = .tintColor
            cell.imageView?.image = UIImage(systemName: "plus")
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let workspaces = workspaces(indexPath.section)
        if indexPath.row < workspaces.count {
            let controller = WorkspaceController(model: model, workspace: workspaces[indexPath.row])
            splitViewController?.showDetailViewController(UINavigationController(rootViewController: controller), sender: self)
        } else { createWorkspace(projects[indexPath.section]) }
    }

    private func connect() {
        let alert = UIAlertController(title: "Bloom Server", message: "Enter the HTTPS address configured for Bloom Gateway. SSH-only servers cannot connect from iOS.", preferredStyle: .alert)
        alert.addTextField { field in field.text = self.model.address; field.placeholder = "https://bloom.example.com"; field.keyboardType = .URL; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let self, let address = alert.textFields?.first?.text else { return }
            Task {
                do {
                    do { try await self.model.connect(address: address) } catch {
                        let userAgent = OIDExternalUserAgentIOS(presenting: self)
                        try await self.model.authentication.signIn(address: address, externalUserAgent: userAgent)
                        try await self.model.connect(address: address)
                    }
                } catch { self.show(error) }
            }
        })
        if model.service != nil {
            alert.addAction(UIAlertAction(title: "Sign out", style: .destructive) { [weak self] _ in
                guard let self else { return }
                do { try self.model.authentication.signOut(address: self.model.address); self.model.disconnect() } catch { self.show(error) }
            })
        }
        present(alert, animated: true)
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
        present(UINavigationController(rootViewController: controller), animated: true)
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
