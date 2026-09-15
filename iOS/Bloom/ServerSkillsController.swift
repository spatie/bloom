import UIKit
import BloomClient

/// UIKit owns navigation. Import review, request identity and inventory live in BloomClient.
final class ServerSkillsController: UITableViewController {
    private let model: MobileConnection
    private let origin: String
    private var generation: Int?
    private var session: ServerSkillsSession?
    private var observation: UUID?
    private var refreshing: Task<Void, Never>?
    private var connectionFailure: String?
    private var selectedWorkspaceID: WorkspaceID?

    init(model: MobileConnection) {
        self.model = model; origin = model.address
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
    deinit { refreshing?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Server Skills"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.importSkills() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Import skills from Git"
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.startRefresh() }, for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        startRefresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshing?.cancel(); refreshing = nil
        if let observation { session?.removeObserver(observation) }; observation = nil
    }

    private func startRefresh() {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    @discardableResult private func refresh() async -> Bool {
        defer { refreshControl?.endRefreshing(); updateUI() }
        guard prepareConnection() else { return false }
        return await session?.refresh() == true
    }

    private func prepareConnection() -> Bool {
        guard model.address == origin, model.canSend, let service = model.service else {
            connectionFailure = "Reconnect to this server to manage its skills."
            return false
        }
        connectionFailure = nil
        if let session {
            if generation != model.generation { session.reconnect(client: service.client) }
        } else { session = ServerSkillsSession(client: service.client, workspaceID: selectedWorkspaceID) }
        generation = model.generation
        if observation == nil { observation = session?.observe { [weak self] in self?.updateUI() } }
        return true
    }

    private var isCurrent: Bool { model.address == origin && model.canSend && generation == model.generation }

    private func updateUI() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = isCurrent && session?.canMutate == true
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1:
            if session?.unsupported == true, connectionFailure == nil { return 0 }
            return (connectionFailure ?? session?.error) == nil && session?.pendingMutationID == nil ? 0 : 1
        default: return max(1, session?.skills.count ?? 0)
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 2 ? "On this server" : nil
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 ? session?.warnings.joined(separator: "\n") : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0, indexPath.row == 1 {
            let workspace = model.catalogue?.workspaces.first { $0.id == selectedWorkspaceID }
            let cell = BloomTheme.cell(title: "Include Project Skills", detail: workspace?.name ?? "Server skills only", symbol: "folder")
            cell.isUserInteractionEnabled = session?.activity == .idle && session?.pendingMutationID == nil
            cell.contentView.alpha = cell.isUserInteractionEnabled ? 1 : 0.5
            return cell
        }
        if indexPath.section == 0 {
            let cell = BloomTheme.cell(title: "Instructions your agents can reuse",
                detail: "Import skills from a Git repository, review their instructions, then choose which agents can use them on this server.",
                symbol: "books.vertical", disclosure: false)
            cell.selectionStyle = .none; return cell
        }
        if indexPath.section == 1 {
            return BloomTheme.cell(title: session?.pendingMutationID == nil ? "Skills couldn’t refresh" : "Request not confirmed",
                detail: (connectionFailure ?? session?.error ?? "The server may have completed the request.")
                    + (session?.pendingMutationID == nil ? "\nTap to refresh." : "\nTap to retry the same request."),
                symbol: "exclamationmark.circle")
        }
        guard let skill = session?.skills.dropFirst(indexPath.row).first else {
            let title = session?.unsupported == true ? "Update Bloom Server" : session?.activity == .loading ? "Loading skills…" : "No skills yet"
            let detail = session?.unsupported == true ? "Install a server version that supports skill management, then refresh."
                : "Choose + to review skills from a Git repository."
            let cell = BloomTheme.cell(title: title, detail: detail, symbol: "books.vertical", disclosure: false)
            cell.selectionStyle = .none; return cell
        }
        let agents = skill.enabledAgents.map { $0 == .claude ? "Claude" : "Codex" }.joined(separator: ", ")
        let source = skill.source == .project ? "Project skill" : skill.isManaged ? "Server skill" : "Unmanaged skill"
        return BloomTheme.cell(title: skill.name, detail: skill.description + "\n" + source + " · " + (agents.isEmpty ? "Disabled" : agents),
            symbol: skill.isManaged ? "book.closed" : "folder")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let session else { startRefresh(); return }
        if indexPath.section == 0, indexPath.row == 1, session.activity == .idle, session.pendingMutationID == nil {
            let picker = ServerSkillScopeController(workspaces: model.catalogue?.workspaces ?? [], selected: selectedWorkspaceID) { [weak self] id in
                guard let self, session.activity == .idle, session.pendingMutationID == nil else { return }
                if let observation { session.removeObserver(observation) }; observation = nil
                selectedWorkspaceID = id; self.session = nil; generation = nil
            }
            navigationController?.pushViewController(picker, animated: true)
        } else if indexPath.section == 1 {
            refreshing = Task { [weak self] in
                guard let self, await refresh(), isCurrent else { return }
                if session.pendingMutationID != nil { await session.retryPendingMutation() }
            }
        } else if indexPath.section == 2, let skill = session.skills.dropFirst(indexPath.row).first {
            navigationController?.pushViewController(ServerSkillDetailController(session: session, skill: skill,
                isCurrent: { [weak self] in self?.isCurrent == true }, refreshConnection: { [weak self] in self?.prepareConnection() == true }), animated: true)
        }
    }

    private func importSkills() {
        guard let session, isCurrent, session.canMutate else { return }
        navigationController?.pushViewController(ServerSkillImportController(session: session,
            isCurrent: { [weak self] in self?.isCurrent == true }, refreshConnection: { [weak self] in self?.prepareConnection() == true }), animated: true)
    }
}
