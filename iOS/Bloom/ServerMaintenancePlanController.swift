import UIKit
import BloomClient

/// Confirmation shows the exact server-prepared version and restart plan. The chosen request is
/// never changed or repeated implicitly if the connection drops after submission.
final class ServerMaintenancePlanController: UITableViewController {
    private let session: ServerMaintenanceSession
    private let plan: ServerMaintenancePlan
    private let serverName: String
    private let isCurrent: () -> Bool
    private var submitting = false

    init(session: ServerMaintenanceSession, plan: ServerMaintenancePlan, serverName: String, isCurrent: @escaping () -> Bool) {
        self.session = session; self.plan = plan; self.serverName = serverName; self.isCurrent = isCurrent
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:plan:serverName:isCurrent:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Review Update"
        BloomTheme.list(tableView); tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.largeTitleDisplayMode = .never
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [3, 2, 2][section] }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [serverName, "What will change", nil][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 { return "This plan expires " + ServerMaintenancePresentation.date(plan.expiresAt) + "." }
        if section == 2 { return "Update When Idle waits for running agents to finish. You can leave Bloom after the server confirms the update." }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            content.text = ["Component", "Installed version", "Update to"][indexPath.row]
            content.secondaryText = [plan.component.title, plan.fromVersion ?? "Not installed", plan.targetVersion][indexPath.row]
            if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { content.prefersSideBySideTextAndSecondaryText = false }
        } else if indexPath.section == 1 {
            content.prefersSideBySideTextAndSecondaryText = false
            content.text = indexPath.row == 0 ? plan.summary : "Services to restart"
            if indexPath.row == 1 { content.secondaryText = plan.restarts.isEmpty ? "None" : plan.restarts.joined(separator: "\n") }
        } else {
            content.text = indexPath.row == 0 ? "Update" : "Update When Idle"
            content.image = UIImage(systemName: indexPath.row == 0 ? "arrow.down.circle" : "clock")
            content.textProperties.color = BloomTheme.accent; content.imageProperties.tintColor = BloomTheme.accent
            cell.selectionStyle = .default; cell.accessibilityTraits.insert(.button)
            cell.isUserInteractionEnabled = !submitting && !plan.isExpired() && isCurrent() && session.canStart
            if !cell.isUserInteractionEnabled { content.textProperties.color = .tertiaryLabel }
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2, !submitting, isCurrent(), session.plan?.id == plan.id else { return }
        guard !plan.isExpired() else {
            show(ConnectionFailure("This update plan has expired. Go back and review the update again.")); return
        }
        let mode: ServerMaintenanceMode = indexPath.row == 0 ? .now : .whenIdle
        submitting = true; navigationItem.hidesBackButton = true; tableView.isUserInteractionEnabled = false
        isModalInPresentation = true; navigationController?.isModalInPresentation = true
        let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progress)
        Task {
            await session.start(mode: mode)
            submitting = false; navigationItem.hidesBackButton = false; navigationItem.rightBarButtonItem = nil
            isModalInPresentation = false; navigationController?.isModalInPresentation = false
            tableView.isUserInteractionEnabled = true
            if let failure = session.failure { show(failure); tableView.reloadData() } else {
                navigationController?.popViewController(animated: true)
            }
        }
    }
}
