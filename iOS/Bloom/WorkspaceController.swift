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
        title = "Workspace Details"
        BloomTheme.list(tableView)
        navigationItem.largeTitleDisplayMode = .never
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "safari"), primaryAction: UIAction { [weak self] _ in self?.preview() }),
            UIBarButtonItem(image: UIImage(systemName: "play"), primaryAction: UIAction { [weak self] _ in self?.scripts() }),
        ]
        navigationItem.rightBarButtonItems?.first?.accessibilityLabel = "Open preview"
        navigationItem.rightBarButtonItems?.last?.accessibilityLabel = "Run project script"
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { do { try await self.model.refresh(); self.tableView.reloadData() } catch { self.show(error) } }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { [workspace.name, "Conversations", "Setup"][section] }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : section == 1 ? sessions.count : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = BloomTheme.cell(title: indexPath.row == 0 ? "Branch" : "Server directory",
                detail: indexPath.row == 0 ? workspace.branch : workspace.path,
                symbol: indexPath.row == 0 ? "arrow.triangle.branch" : "folder", disclosure: false)
            cell.selectionStyle = .none
            return cell
        }
        if indexPath.section == 1 {
            let session = sessions[indexPath.row]
            let state = session.state == "running" ? "Working" : session.state == "waiting" ? "Needs your answer" : "Ready"
            return BloomTheme.cell(title: session.title, detail: "\(session.model) · \(state)", symbol: "bubble.left.and.bubble.right")
        }
        let current = model.catalogue?.workspaces.first { $0.id == workspace.id } ?? workspace
        let succeeded = current.setupState == "succeeded" || current.setupState == "skipped"
        let title = succeeded ? "Workspace ready" : current.setupState == "running" ? "Setting up workspace" : current.setupState == "failed" ? "Setup needs attention" : "Preparing workspace"
        let cell = BloomTheme.cell(title: title, detail: succeeded ? "Everything is in place. Start a conversation or open your preview." : current.setupLog,
                                  symbol: succeeded ? "checkmark.circle" : "wrench.and.screwdriver", disclosure: !current.setupLog.isEmpty)
        cell.selectionStyle = current.setupLog.isEmpty ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 { showSetupOutput(); return }
        guard indexPath.section == 1 else { return }
        navigationController?.pushViewController(ConversationController(model: model, session: sessions[indexPath.row]), animated: true)
    }

    private func showSetupOutput() {
        let current = model.catalogue?.workspaces.first { $0.id == workspace.id } ?? workspace
        guard !current.setupLog.isEmpty else { return }
        let screen = UIViewController()
        screen.title = "Setup Output"
        let output = UITextView()
        output.text = current.setupLog
        output.isEditable = false
        output.alwaysBounceVertical = true
        output.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        output.adjustsFontForContentSizeCategory = true
        output.backgroundColor = BloomTheme.background
        output.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        screen.view = output
        screen.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Copy", primaryAction: UIAction { _ in
            UIPasteboard.general.string = current.setupLog
            UIAccessibility.post(notification: .announcement, argument: "Setup output copied")
        })
        navigationController?.pushViewController(screen, animated: true)
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
        let alert = UIAlertController(title: "Open preview", message: "Enter the app’s address on the server. Bloom opens local ports through your SSH connection.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://preview.example.com"; $0.text = port > 0 ? "http://localhost:\(port)" : ""; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
            guard let self, let address = alert.textFields?.first?.text else { return }
            Task {
                do {
                    let lease = try await self.model.preparePreview(address: address)
                    guard self.viewIfLoaded?.window != nil, let navigation = self.navigationController else { lease.close(); return }
                    navigation.pushViewController(PreviewController(preview: lease), animated: true)
                } catch { self.show(error) }
            }
        })
        present(alert, animated: true)
    }
}
