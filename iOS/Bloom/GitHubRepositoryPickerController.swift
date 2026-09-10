import UIKit
import BloomClient

/// Repository discovery uses the server's signed-in GitHub account, including private repositories.
final class GitHubRepositoryPickerController: UITableViewController, UISearchResultsUpdating {
    private let model: MobileConnection
    private let origin: String
    private let onImported: (RemoteProject) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private var repositories: [GitHubRepositoryListing] = []
    private var page = 0
    private var canLoadMore = false
    private var query = ""
    private var work: Task<Void, Never>?
    private var generation = 0
    private var importing = false

    init(model: MobileConnection, onImported: @escaping (RemoteProject) -> Void) {
        self.model = model; origin = model.address; self.onImported = onImported
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:onImported:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GitHub repositories"
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "Search repositories"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        tableView.rowHeight = UITableView.automaticDimension
        load(reset: true)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !importing, isMovingFromParent || navigationController?.isBeingDismissed == true { work?.cancel() }
    }
    func updateSearchResults(for searchController: UISearchController) {
        guard !importing else { return }
        let updated = searchController.searchBar.text ?? ""
        guard updated != query else { return }
        query = updated
        load(reset: true)
    }
    private func load(reset: Bool) {
        guard !importing, model.address == origin, let service = model.service else { return }
        work?.cancel(); generation += 1
        let generation = generation, query = query, requestedPage = reset ? 1 : page + 1
        if reset { repositories = []; page = 0; canLoadMore = false; tableView.reloadData() }
        var loading = UIContentUnavailableConfiguration.loading(); loading.text = "Loading repositories"
        if repositories.isEmpty { tableView.backgroundView = UIContentUnavailableView(configuration: loading) }
        work = Task { [weak self] in
            do {
                if reset, !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                let result = try await service.githubRepositories(query: query, page: requestedPage)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                var seen = Set(self.repositories.map(\.id))
                self.repositories += result.filter { seen.insert($0.id).inserted }
                self.page = requestedPage; self.canLoadMore = result.count == 50 && requestedPage < 20
                self.tableView.backgroundView = nil
                self.tableView.reloadData()
                if self.repositories.isEmpty { self.empty("No matching repositories", error: nil) }
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.empty("Could not load repositories", error: error.localizedDescription)
            }
        }
    }
    private func empty(_ title: String, error: String?) {
        var content = UIContentUnavailableConfiguration.empty(); content.text = title; content.secondaryText = error
        if error != nil {
            content.button.title = "Retry"
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load(reset: true) }
        }
        tableView.backgroundView = UIContentUnavailableView(configuration: content)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { repositories.count + (canLoadMore ? 1 : 0) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.row == repositories.count { content.text = "Load more repositories" } else {
            let repo = repositories[indexPath.row]
            content.text = repo.nameWithOwner; content.secondaryText = repo.description
            content.image = UIImage(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
            content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 2
        }
        cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == repositories.count { load(reset: false); return }
        guard !importing, model.address == origin, let service = model.service else { return }
        let name = repositories[indexPath.row].nameWithOwner
        importing = true; tableView.isUserInteractionEnabled = false; search.searchBar.isUserInteractionEnabled = false
        isModalInPresentation = true; navigationController?.isModalInPresentation = true
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progress)
        title = "Importing repository"
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importing = false; self.tableView.isUserInteractionEnabled = true
                self.search.searchBar.isUserInteractionEnabled = true; self.isModalInPresentation = false
                self.navigationController?.isModalInPresentation = false; self.navigationItem.hidesBackButton = false
                self.navigationItem.leftBarButtonItem?.isEnabled = true; self.navigationItem.rightBarButtonItem = nil
                self.title = "GitHub repositories"
            }
            do {
                let scope = "import:\(name)"
                let command = try CreationRecovery.store.prepare(service.importGitHubCommand(name), origin: origin, scope: scope)
                let project = try service.importedProject(await service.client.request(command))
                try CreationRecovery.store.acknowledge(command, origin: origin, scope: scope)
                try? await model.refresh()
                onImported(project)
            } catch { show(error) }
        }
    }
}
