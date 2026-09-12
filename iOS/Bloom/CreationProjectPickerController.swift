import UIKit
import BloomClient

/// Project selection stays searchable without mixing server projects with a GitHub import.
final class CreationProjectPickerController: UITableViewController, UISearchResultsUpdating {
    private let model: MobileConnection
    private let selected: (RemoteProject) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private var projects: [RemoteProject] = []
    private var filtered: [RemoteProject] {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }

    init(model: MobileConnection, selected: @escaping (RemoteProject) -> Void) {
        self.model = model; self.selected = selected; super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:selected:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Choose Project"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "Find a project"
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        projects = model.catalogue?.repositories.filter { !$0.hidden } ?? []
        tableView.reloadData()
    }
    func updateSearchResults(for searchController: UISearchController) { tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? filtered.count : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "On your server" : nil }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0, filtered.isEmpty else { return nil }
        return projects.isEmpty ? "Bring a project over from GitHub to get started." : "No projects match your search."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            return BloomTheme.cell(title: "Import from GitHub", detail: "Use the GitHub account on your server.", symbol: "arrow.down.circle")
        }
        return BloomTheme.cell(title: filtered[indexPath.row].name, symbol: "folder")
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            navigationController?.pushViewController(GitHubRepositoryPickerController(model: model) { [weak self] project in
                self?.selected(project); self?.navigationController?.popToRootViewController(animated: true)
            }, animated: true)
        } else { selected(filtered[indexPath.row]); navigationController?.popViewController(animated: true) }
    }
}
