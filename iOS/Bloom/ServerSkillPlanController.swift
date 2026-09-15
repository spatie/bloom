import UIKit
import BloomClient

final class ServerSkillPlanController: UITableViewController {
    private let session: ServerSkillsSession
    private let plan: ServerSkillsPlan
    private let updating: ServerSkill?
    private let isCurrent: () -> Bool
    private let refreshConnection: () async -> Bool
    private var names: Set<String>
    private var agents: Set<ServerSkillAgent>
    private var applying = false

    init(session: ServerSkillsSession, plan: ServerSkillsPlan, updating: ServerSkill?,
         isCurrent: @escaping () -> Bool, refreshConnection: @escaping () async -> Bool) {
        self.session = session; self.plan = plan; self.updating = updating
        self.isCurrent = isCurrent; self.refreshConnection = refreshConnection
        names = Set(plan.skills.map(\.name)); agents = Set(updating?.enabledAgents ?? ServerSkillAgent.allCases)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:plan:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Review Skills"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView); tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: updating == nil ? "Install" : "Update",
            primaryAction: UIAction { [weak self] _ in self?.apply() })
        updateButton()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); updateButton() }
    private func updateButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !applying && !names.isEmpty && plan.expiresAt > Date()
            && isCurrent() && session.canMutate && session.plan?.id == plan.id
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [1, plan.skills.count, ServerSkillAgent.allCases.count][section] }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { ["Reviewed source", "Choose skills", "Available to"][section] }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return plan.warnings.joined(separator: "\n") }
        if section == 1 { return "Tap a skill to include it. Use its info button to read the instructions and included file names." }
        return agents.isEmpty ? "The selected skills will be installed disabled." : "These agents will have access to every selected skill on this server."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let detail = (plan.commit.map { "Commit " + $0 + "\n" } ?? "") + "Preview expires " + plan.expiresAt.formatted(date: .omitted, time: .shortened)
            let cell = BloomTheme.cell(title: plan.repositoryURL ?? "Personal skills", detail: detail, symbol: "shippingbox", disclosure: false)
            cell.selectionStyle = .none; return cell
        }
        if indexPath.section == 1 {
            let skill = plan.skills[indexPath.row]
            let cell = BloomTheme.cell(title: skill.name, detail: skill.description,
                symbol: names.contains(skill.name) ? "checkmark.circle.fill" : "circle", disclosure: false)
            cell.accessoryType = .detailButton
            cell.accessibilityValue = names.contains(skill.name) ? "Included" : "Not included"
            return cell
        }
        let agent = ServerSkillAgent.allCases[indexPath.row]
        let cell = BloomTheme.cell(title: agent == .claude ? "Claude" : "Codex", symbol: "sparkle", disclosure: false)
        cell.accessoryType = agents.contains(agent) ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !applying else { return }
        if indexPath.section == 1 {
            let name = plan.skills[indexPath.row].name
            if !names.insert(name).inserted { names.remove(name) }
        } else if indexPath.section == 2 {
            let agent = ServerSkillAgent.allCases[indexPath.row]
            if !agents.insert(agent).inserted { agents.remove(agent) }
        }
        tableView.reloadData(); updateButton()
    }
    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        navigationController?.pushViewController(ServerSkillDetailController(session: session, skill: plan.skills[indexPath.row], planID: plan.id,
            isCurrent: isCurrent, refreshConnection: refreshConnection), animated: true)
    }
    private func apply() {
        guard !applying, isCurrent(), session.canMutate else { return }
        applying = true; tableView.isUserInteractionEnabled = false; navigationItem.hidesBackButton = true
        navigationController?.isModalInPresentation = true
        updateButton()
        let selectedNames = plan.skills.map(\.name).filter { names.contains($0) }
        let selectedAgents = ServerSkillAgent.allCases.filter { agents.contains($0) }
        Task {
            let success = await session.apply(planID: plan.id, selectedSkillNames: selectedNames, agents: selectedAgents)
            applying = false; tableView.isUserInteractionEnabled = true; navigationItem.hidesBackButton = false
            navigationController?.isModalInPresentation = false; updateButton()
            if success, let list = navigationController?.viewControllers.first(where: { $0 is ServerSkillsController }) {
                navigationController?.popToViewController(list, animated: true)
            } else { show(ConnectionFailure(session.error ?? "The skills could not be installed.")) }
        }
    }
}
