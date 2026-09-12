import UIKit
import BloomClient

final class ServerMaintenanceJobController: UITableViewController {
    private let session: ServerMaintenanceSession
    private let jobID: String
    private let isCurrent: () -> Bool
    private var observation: UUID?
    private var polling: Task<Void, Never>?
    private var shownLogCount = 0
    private var job: ServerMaintenanceJob? { session.jobs.first { $0.id == jobID } }

    init(session: ServerMaintenanceSession, jobID: String, isCurrent: @escaping () -> Bool) {
        self.session = session; self.jobID = jobID; self.isCurrent = isCurrent
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:jobID:isCurrent:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = job?.component.title ?? "Update Details"
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Copy Log", primaryAction: UIAction { [weak self] _ in self?.copyLog() })
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in
            Task { guard let self else { return }; await self.refresh(); self.refreshControl?.endRefreshing() }
        }, for: .valueChanged)
        updateUI()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        observation = session.observe { [weak self] in self?.updateUI() }
        polling = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled, isCurrent(), job?.isActive == true {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await refresh()
            }
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        polling?.cancel(); polling = nil
        if let observation { session.removeObserver(observation) }; observation = nil
    }
    private func refresh() async {
        guard !Task.isCancelled else { return }
        guard isCurrent() else { updateUI(); return }
        await session.poll(jobID: jobID)
    }
    private func updateUI() {
        guard isViewLoaded else { return }
        let followsOutput = tableView.contentOffset.y + tableView.bounds.height >= tableView.contentSize.height - 80
        let previousCount = shownLogCount
        shownLogCount = job?.logs.count ?? 0
        tableView.reloadData()
        if followsOutput, shownLogCount > previousCount {
            tableView.scrollToRow(at: IndexPath(row: shownLogCount - 1, section: 1), at: .bottom, animated: false)
        }
        if job?.canCancel == true {
            toolbarItems = [.flexibleSpace(), UIBarButtonItem(title: "Cancel Update…", primaryAction: UIAction { [weak self] _ in self?.confirmCancellation() }), .flexibleSpace()]
            toolbarItems?[1].isEnabled = session.activity == .idle && isCurrent()
        } else { toolbarItems = [] }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : job?.logs.count ?? 0 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Status" : "Server output" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        if !isCurrent() { return "Reconnect to this server, then reopen update details to see current progress. The update continues on the server." }
        return session.failure.map { $0.message + "\n" + $0.recovery }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0
        if indexPath.section == 0 {
            content.text = job?.phase.title ?? "Update unavailable"
            content.secondaryText = job.map { [$0.message, ServerMaintenancePresentation.date($0.updatedAt)].compactMap { $0 }.joined(separator: "\n") }
        } else {
            content.text = job?.logs[indexPath.row].message
            content.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
        cell.contentConfiguration = content; cell.selectionStyle = .none
        return cell
    }
    private func confirmCancellation() {
        guard let job, job.canCancel, isCurrent() else { return }
        let alert = UIAlertController(title: "Cancel this update?", message: "Bloom will cancel only if the update has not reached a step that must finish safely.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Update", style: .cancel))
        alert.addAction(UIAlertAction(title: "Cancel Update", style: .destructive) { [weak self] _ in
            guard let self, isCurrent() else { return }
            Task { await session.cancel(jobID: jobID) }
        })
        present(alert, animated: true)
    }
    private func copyLog() {
        guard let job else { return }
        UIPasteboard.general.string = ServerMaintenancePresentation.report(server: "Update details", components: [], jobs: [job], failure: session.failure)
        UIAccessibility.post(notification: .announcement, argument: "Update log copied")
    }
}
