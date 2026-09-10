import UIKit
import BloomClient

final class CreationProjectPickerController: UITableViewController {
    private let model: MobileConnection
    private let selected: (RemoteProject) -> Void
    private var projects: [RemoteProject] = []
    init(model: MobileConnection, selected: @escaping (RemoteProject) -> Void) {
        self.model = model; self.selected = selected; super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:selected:)") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Project" }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        projects = model.catalogue?.repositories.filter { !$0.hidden } ?? []
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { projects.count + 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = indexPath.row == projects.count ? "Import from GitHub" : projects[indexPath.row].name
        content.image = UIImage(systemName: indexPath.row == projects.count ? "arrow.down.circle" : "folder")
        cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.row == projects.count {
            navigationController?.pushViewController(GitHubRepositoryPickerController(model: model) { [weak self] project in
                self?.selected(project); self?.navigationController?.popToRootViewController(animated: true)
            }, animated: true)
        } else { selected(projects[indexPath.row]); navigationController?.popViewController(animated: true) }
    }
}
