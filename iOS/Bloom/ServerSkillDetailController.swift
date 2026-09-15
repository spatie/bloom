import UIKit
import BloomClient

final class ServerSkillDetailController: UITableViewController {
    private let session: ServerSkillsSession
    private let original: ServerSkill
    private let planID: String?
    private let isCurrent: () -> Bool
    private let refreshConnection: () async -> Bool
    private var observation: UUID?
    private var skill: ServerSkill { planID == nil ? session.skills.first { $0.id == original.id } ?? original : original }
    private var filePaths: [String] {
        if session.contentSkillID == original.id, session.contentPlanID == planID, let detail = session.detailSkill { return detail.filePaths }
        return skill.filePaths
    }

    init(session: ServerSkillsSession, skill: ServerSkill, planID: String? = nil,
         isCurrent: @escaping () -> Bool, refreshConnection: @escaping () async -> Bool) {
        self.session = session; original = skill; self.planID = planID
        self.isCurrent = isCurrent; self.refreshConnection = refreshConnection
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:skill:)") }

    override func viewDidLoad() {
        super.viewDidLoad(); title = original.name
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView); tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in
            Task { guard let self, await self.refreshConnection() else { return }; await self.session.refresh(); self.tableView.reloadData() }
        })
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observation = session.observe { [weak self] in self?.tableView.reloadData() }
        tableView.reloadData()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let observation { session.removeObserver(observation) }; observation = nil
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 5 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: 1
        case 1: planID == nil && skill.isManaged ? ServerSkillAgent.allCases.count : 0
        case 2: 1
        case 3: filePaths.count
        default: planID == nil && skill.isManaged ? (skill.source == .git ? 2 : 1) : 0
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 3, filePaths.isEmpty { return nil }
        return [nil, "Available to", "Instructions", "Included files", nil][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return skill.warning }
        if section == 1, planID == nil { return skill.isManaged ? "Choose which agents can discover this skill." : "This skill belongs to its original location and is read-only here." }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let source = skill.repositoryURL ?? skill.path
            let commit = skill.commit.map { "\nCommit " + $0 } ?? ""
            let cell = BloomTheme.cell(title: skill.description.isEmpty ? skill.name : skill.description,
                detail: source + commit + "\n\(skill.fileCount) files", symbol: "book.closed", disclosure: false)
            cell.selectionStyle = .none; return cell
        }
        if indexPath.section == 1 {
            let agent = ServerSkillAgent.allCases[indexPath.row]
            let cell = BloomTheme.cell(title: agent == .claude ? "Claude" : "Codex", symbol: "sparkle", disclosure: false)
            cell.accessoryType = skill.enabledAgents.contains(agent) ? .checkmark : .none
            cell.isUserInteractionEnabled = isCurrent() && session.canMutate
            cell.contentView.alpha = cell.isUserInteractionEnabled ? 1 : 0.5
            return cell
        }
        if indexPath.section == 2 { return BloomTheme.cell(title: "Read SKILL.md", detail: "Review the instructions given to your agent.", symbol: "doc.text") }
        if indexPath.section == 3 {
            let cell = BloomTheme.cell(title: filePaths[indexPath.row], symbol: "doc", disclosure: false)
            cell.selectionStyle = .none; return cell
        }
        let isUpdate = skill.source == .git && indexPath.row == 0
        let cell = BloomTheme.cell(title: isUpdate ? "Review Update from Git" : "Remove Skill", symbol: isUpdate ? "arrow.down.circle" : "trash")
        if !isUpdate, var content = cell.contentConfiguration as? UIListContentConfiguration {
            content.textProperties.color = .systemRed; content.imageProperties.tintColor = .systemRed; cell.contentConfiguration = content
        }
        cell.isUserInteractionEnabled = isCurrent() && session.canMutate
        cell.contentView.alpha = cell.isUserInteractionEnabled ? 1 : 0.5
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 {
            navigationController?.pushViewController(ServerSkillInstructionsController(session: session, skill: skill, planID: planID,
                refreshConnection: refreshConnection), animated: true)
        } else if indexPath.section == 1, isCurrent(), session.canMutate {
            let snapshot = skill
            let agent = ServerSkillAgent.allCases[indexPath.row]
            let enabled = Set(snapshot.enabledAgents).symmetricDifference([agent])
            Task {
                let success = await session.setEnabled(skillID: snapshot.id, revision: snapshot.revision,
                    agents: ServerSkillAgent.allCases.filter { enabled.contains($0) })
                if !success { show(ConnectionFailure(session.error ?? "The skill could not be changed.")) }
            }
        } else if indexPath.section == 4, isCurrent(), session.canMutate {
            if skill.source == .git && indexPath.row == 0 {
                navigationController?.pushViewController(ServerSkillImportController(session: session, updating: skill,
                    isCurrent: isCurrent, refreshConnection: refreshConnection), animated: true)
            } else { confirmRemoval() }
        }
    }
    private func confirmRemoval() {
        let snapshot = skill
        let alert = UIAlertController(title: "Remove \(snapshot.name)?", message: "This removes the managed skill from this server. You can import it again later.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove Skill", style: .destructive) { [weak self] _ in
            guard let self, isCurrent() else { return }
            Task {
                if await session.remove(skillID: snapshot.id, revision: snapshot.revision) {
                    navigationController?.popViewController(animated: true)
                } else { show(ConnectionFailure(session.error ?? "The skill could not be removed.")) }
            }
        })
        present(alert, animated: true)
    }
}
