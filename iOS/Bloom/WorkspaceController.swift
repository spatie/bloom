import UIKit
import BloomClient

final class WorkspaceController: UITableViewController {
    private let model: MobileConnection
    private let workspace: RemoteWorkspace
    private var sessions: [RemoteSession] { model.catalogue?.sessions.filter { $0.workspaceID == workspace.id } ?? [] }

    init(model: MobileConnection, workspace: RemoteWorkspace) {
        self.model = model; self.workspace = workspace
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:workspace:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = workspace.name
        navigationItem.prompt = workspace.branch
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Preview", primaryAction: UIAction { [weak self] _ in self?.preview() }),
            UIBarButtonItem(title: "Run", primaryAction: UIAction { [weak self] _ in self?.scripts() }),
        ]
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { do { try await self.model.refresh(); self.tableView.reloadData() } catch { self.show(error) } }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Conversations" : "Setup" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? sessions.count : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let session = sessions[indexPath.row]
            cell.textLabel?.text = session.title
            cell.detailTextLabel?.text = "\(session.model) · \(session.state)"
            cell.accessoryType = .disclosureIndicator
        } else {
            let current = model.catalogue?.workspaces.first { $0.id == workspace.id } ?? workspace
            cell.textLabel?.text = current.setupState.capitalized
            cell.detailTextLabel?.text = current.setupLog
            cell.detailTextLabel?.numberOfLines = 8
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        navigationController?.pushViewController(ConversationController(model: model, session: sessions[indexPath.row]), animated: true)
    }

    private func scripts() {
        guard let service = model.service else { return }
        Task {
            do {
                let result = try await service.client.request(.call("workspace", ["workspaceID": .string(workspace.id.rawValue), "action": .object(["runScripts": .object([:])])]))
                let scripts = result["runScripts"]?["_0"]?.arrayValue ?? []
                let alert = UIAlertController(title: "Run on server", message: scripts.isEmpty ? "No run scripts are configured for this project." : nil, preferredStyle: .actionSheet)
                for script in scripts {
                    guard let id = script["id"]?.stringValue, let name = script["name"]?.stringValue else { continue }
                    alert.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                        let command = RemoteCommand.call("workspace", ["workspaceID": .string(self?.workspace.id.rawValue ?? ""), "action": .object(["runScript": .object(["id": .string(id)])])])
                        self?.execute(command, service: service)
                    })
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?.last
                self.present(alert, animated: true)
            } catch { self.show(error) }
        }
    }

    private func execute(_ command: RemoteCommand, service: RemoteWorkspaceService) {
        Task {
            do { _ = try await service.client.request(command); try await model.refresh(); tableView.reloadData() } catch {
                show(error, retry: { [weak self] in self?.execute(command, service: service) })
            }
        }
    }

    private func preview() {
        let port = model.catalogue?.workspaces.first { $0.id == workspace.id }?.port ?? workspace.port
        let alert = UIAlertController(title: "Open preview", message: "Use a registered HTTPS preview address, or a server localhost address with a Tailscale Serve mapping.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://preview.example.com"; $0.text = port > 0 ? "http://localhost:\(port)" : ""; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
            guard let self, let address = alert.textFields?.first?.text, let service = self.model.service else { return }
            Task {
                do {
                    let reply = try await service.client.request(.call("previewAddress", ["_0": .string(address)]))
                    guard let address = reply["text"]?["_0"]?.stringValue,
                          let url = URL(string: address), url.scheme == "https", url.host != nil,
                          url.user == nil, url.password == nil else {
                        throw ConnectionFailure("iOS cannot open an SSH tunnel. Configure this port as an HTTPS preview on Bloom Gateway or Tailscale Serve first.")
                    }
                    self.navigationController?.pushViewController(PreviewController(url: url), animated: true)
                } catch { self.show(error) }
            }
        })
        present(alert, animated: true)
    }
}
