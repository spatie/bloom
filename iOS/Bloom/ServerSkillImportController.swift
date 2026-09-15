import UIKit
import BloomClient

final class ServerSkillImportController: UITableViewController, UITextFieldDelegate {
    private let session: ServerSkillsSession
    private let updating: ServerSkill?
    private let isCurrent: () -> Bool
    private let refreshConnection: () async -> Bool
    private let repository = UITextField()
    private let reference = UITextField()
    private var preparing = false

    init(session: ServerSkillsSession, updating: ServerSkill? = nil, isCurrent: @escaping () -> Bool,
         refreshConnection: @escaping () async -> Bool) {
        self.session = session; self.updating = updating; self.isCurrent = isCurrent; self.refreshConnection = refreshConnection
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:isCurrent:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = updating == nil ? "Import Skills" : "Review Skill Update"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView); tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.keyboardDismissMode = .interactive
        repository.placeholder = "https://github.com/owner/skills"
        repository.text = updating?.repositoryURL
        repository.keyboardType = .URL
        repository.accessibilityLabel = "Git repository URL"
        reference.placeholder = "Default branch"
        reference.text = updating?.ref
        reference.accessibilityLabel = "Branch, tag or commit"
        for field in [repository, reference] {
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
            field.clearButtonMode = .whileEditing; field.delegate = self
            field.addAction(UIAction { [weak self] _ in self?.updateButton() }, for: .editingChanged)
        }
        repository.returnKeyType = .next; reference.returnKeyType = .go
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Review", primaryAction: UIAction { [weak self] _ in self?.prepare() })
        updateButton()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); updateButton() }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 1 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Bloom downloads a preview first. You’ll review the instructions and choose agents before anything is installed." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = BloomTheme.cell(title: "Review sources you trust", detail: "Skills supply instructions and supporting files to your agents. Review SKILL.md before enabling a skill.", symbol: "checkmark.shield", disclosure: false)
            cell.selectionStyle = .none; return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.selectionStyle = .none
        let label = BloomTheme.label(indexPath.row == 0 ? "Repository" : "Branch, tag or commit", style: .caption1, secondary: true)
        let field = indexPath.row == 0 ? repository : reference
        let stack = UIStackView(arrangedSubviews: [label, field]); stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor)
        ])
        return cell
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === repository { reference.becomeFirstResponder() } else { prepare() }
        return false
    }
    private func updateButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !preparing && !(repository.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func prepare() {
        guard !preparing, session.pendingMutationID == nil else { return }
        view.endEditing(true); preparing = true; tableView.isUserInteractionEnabled = false
        navigationItem.rightBarButtonItem?.title = "Reviewing…"; updateButton()
        let source = (repository.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = (reference.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { preparing = false; tableView.isUserInteractionEnabled = true; navigationItem.rightBarButtonItem?.title = "Review"; updateButton() }
            guard await refreshConnection(), isCurrent() else { show(ConnectionFailure("Reconnect to this server and try again.")); return }
            if await session.previewGit(repositoryURL: source, ref: ref.isEmpty ? nil : ref, collectionID: updating?.collectionID), let plan = session.plan {
                navigationController?.pushViewController(ServerSkillPlanController(session: session, plan: plan,
                    updating: updating, isCurrent: isCurrent, refreshConnection: refreshConnection), animated: true)
            } else { show(ConnectionFailure(session.error ?? "The repository could not be reviewed.")) }
        }
    }
}
