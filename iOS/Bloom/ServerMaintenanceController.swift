import UIKit
import BloomClient
import BloomAuthentication

/// The same maintenance session drives Mac and mobile. This screen observes durable jobs rather
/// than owning an update process, so leaving it never stops server maintenance.
final class ServerMaintenanceController: UITableViewController {
    private let model: MobileConnection
    private let origin: String
    private var access: ServerMaintenanceAccess?
    private var generation: Int?
    private var observation: UUID?
    private var connectionObservation: UUID?
    private var polling: Task<Void, Never>?
    private var connectionFailure: String?
    private var serverName: String { URLComponents(string: origin)?.host ?? "your server" }
    private var session: ServerMaintenanceSession? { access?.session }
    private var isCurrent: Bool { model.address == origin && generation == model.generation && model.canSend }

    init(model: MobileConnection) {
        self.model = model; origin = model.address
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Server Updates"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in Task { await self?.refresh() } }, for: .valueChanged)
        toolbarItems = [UIBarButtonItem(title: "Copy Report", primaryAction: UIAction { [weak self] _ in self?.copyReport() }),
                        .flexibleSpace(), UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in Task { await self?.refresh() } })]
        toolbarItems?.last?.accessibilityLabel = "Refresh server updates"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        connectionObservation = model.observe { [weak self] in
            guard let self else { return }
            if !isCurrent { startObserving() }
        }
        startObserving()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        polling?.cancel(); polling = nil
        if let observation { session?.removeObserver(observation) }; observation = nil
        if let connectionObservation { model.removeObserver(connectionObservation) }; connectionObservation = nil
    }

    private func startObserving() {
        polling?.cancel()
        polling = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled, isCurrent, let session {
                do { try await Task.sleep(for: .seconds(session.hasActiveJobs || session.pendingMutationID != nil ? 2 : 10)) } catch { return }
                guard !Task.isCancelled, isCurrent else { return }
                if session.authorized { await session.poll() }
            }
        }
    }

    private func refresh() async {
        defer { refreshControl?.endRefreshing(); updateUI() }
        guard model.address == origin, model.canSend, let service = model.service else {
            connectionFailure = "Reconnect to this server to manage updates. Updates already running will continue."
            return
        }
        connectionFailure = nil
        if generation != model.generation || access == nil {
            if let observation { session?.removeObserver(observation) }
            access = ServerMaintenanceAccess(serverID: (try? RemoteOrigin.canonical(origin)) ?? origin, client: service.client)
            generation = model.generation; observation = nil
        }
        if observation == nil {
            observation = session?.observe { [weak self] in self?.updateUI() }
        }
        await access?.refresh()
    }

    private func updateUI() {
        tableView.reloadData()
        if session?.isPreparing == true || session?.isSubmitting == true {
            let progress = UIActivityIndicatorView(style: .medium)
            progress.accessibilityLabel = session?.isPreparing == true ? "Preparing update" : "Confirming request"
            progress.startAnimating(); navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progress)
        } else { navigationItem.rightBarButtonItem = nil }
        toolbarItems?.last?.isEnabled = isCurrent && session?.activity == .idle
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: 1
        case 1: (connectionFailure ?? access?.credentialFailure ?? session?.failure?.message) == nil ? 0 : 1
        case 2: max(1, session?.components.count ?? 0)
        default: max(1, session?.jobs.count ?? 0)
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Maintenance access", nil, "Components", "Activity"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "Maintenance access allows server updates. It is separate from workspace access and agent sign-ins." }
        if section == 3 { return "Updates continue on the server when you leave Bloom. Return here to see their progress." }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let supported = session?.unsupported != true
            return BloomTheme.cell(title: session?.authorized == true ? "Manage Maintenance Access" : "Add Maintenance Access",
                detail: supported ? "Stored only in this device’s Keychain." : "Install Bloom’s maintenance service from server setup on your Mac first.",
                symbol: "lock.shield", disclosure: supported)
        }
        if indexPath.section == 1 {
            let message = connectionFailure ?? access?.credentialFailure ?? session?.failure?.message ?? ""
            let detail = session?.pendingMutationID != nil ? "Tap to retry the same request safely." : session?.failure?.recovery
            return BloomTheme.cell(title: message, detail: detail, symbol: "exclamationmark.circle", disclosure: session?.pendingMutationID != nil)
        }
        if indexPath.section == 2, let component = session?.components.dropFirst(indexPath.row).first {
            let versions = "Installed: " + (component.installedVersion ?? "Unavailable")
                + (component.availableVersion.map { "\nAvailable: " + $0 } ?? "")
            let cell = BloomTheme.cell(title: component.title, detail: versions + (component.detail.isEmpty ? "" : "\n" + component.detail),
                                      symbol: "shippingbox", disclosure: component.canUpdate)
            if var content = cell.contentConfiguration as? UIListContentConfiguration {
                content.secondaryTextProperties.numberOfLines = 0; cell.contentConfiguration = content
            }
            return cell
        }
        if indexPath.section == 3, let job = session?.jobs.dropFirst(indexPath.row).first {
            let cell = BloomTheme.cell(title: job.component.title + " " + job.targetVersion,
                detail: job.phase.title + " · " + ServerMaintenancePresentation.date(job.updatedAt),
                symbol: job.phase.needsAttention ? "exclamationmark.circle" : "clock")
            if job.isActive { let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating(); cell.accessoryView = progress }
            return cell
        }
        let checking = session == nil || session?.isLoading == true
        let text = checking ? "Checking your server…" : session?.unsupported == true ? "Managed updates aren’t available yet"
            : session?.authorized != true ? "Add maintenance access to continue" : indexPath.section == 2 ? "No components available" : "No updates yet"
        let cell = BloomTheme.cell(title: text, symbol: checking ? "arrow.triangle.2.circlepath" : "shippingbox", disclosure: false)
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard isCurrent, let access, let session else { return }
        if indexPath.section == 0, !session.unsupported {
            navigationController?.pushViewController(ServerMaintenanceAccessController(access: access), animated: true)
        } else if indexPath.section == 1, session.pendingMutationID != nil {
            let alert = UIAlertController(title: "Retry maintenance request?", message: "The server may already have started it. Bloom will retry the same request to confirm what happened.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Retry Request", style: .default) { [weak self] _ in
                guard self?.isCurrent == true else { return }
                Task { await session.retryPendingMutation() }
            })
            present(alert, animated: true)
        } else if indexPath.section == 2, let component = session.components.dropFirst(indexPath.row).first, component.canUpdate,
                  session.activity == .idle, session.authorized, session.pendingMutationID == nil, !session.hasActiveJobs {
            Task { [weak self] in
                await session.prepare(component: component.id)
                guard let self, isCurrent, let plan = session.plan, viewIfLoaded?.window != nil else { return }
                navigationController?.pushViewController(ServerMaintenancePlanController(session: session, plan: plan,
                    serverName: serverName, isCurrent: { [weak self] in self?.isCurrent == true }), animated: true)
            }
        } else if indexPath.section == 3, let job = session.jobs.dropFirst(indexPath.row).first {
            navigationController?.pushViewController(ServerMaintenanceJobController(session: session, jobID: job.id,
                isCurrent: { [weak self] in self?.isCurrent == true }), animated: true)
        }
    }

    private func copyReport() {
        UIPasteboard.general.string = ServerMaintenancePresentation.report(server: serverName,
            components: session?.components ?? [], jobs: session?.jobs ?? [], failure: session?.failure)
        UIAccessibility.post(notification: .announcement, argument: "Maintenance report copied")
    }
}
