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
    private var loading = false
    private var importingRepository: String?

    init(model: MobileConnection, onImported: @escaping (RemoteProject) -> Void) {
        self.model = model; origin = model.address; self.onImported = onImported
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:onImported:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Import from GitHub"
        navigationItem.largeTitleDisplayMode = .never
        preferredContentSize = CGSize(width: 640, height: 720)
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        definesPresentationContext = true
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
        guard !importing else { return }
        guard model.address == origin, let service = model.service else {
            empty("Connect to browse GitHub", error: "Reconnect to your server, then try again.")
            return
        }
        work?.cancel(); generation += 1
        loading = true
        let generation = generation, query = query, requestedPage = reset ? 1 : page + 1
        if reset { repositories = []; page = 0; canLoadMore = false }
        tableView.reloadData()
        var loadingConfiguration = UIContentUnavailableConfiguration.loading(); loadingConfiguration.text = "Loading repositories"
        if repositories.isEmpty { tableView.backgroundView = UIContentUnavailableView(configuration: loadingConfiguration) }
        work = Task { [weak self] in
            do {
                if reset, !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                let result = try await service.githubRepositories(query: query, page: requestedPage)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                var seen = Set(self.repositories.map(\.id))
                self.repositories += result.filter { seen.insert($0.id).inserted }
                self.loading = false
                self.page = requestedPage; self.canLoadMore = result.count == 50 && requestedPage < 20
                self.tableView.backgroundView = nil
                self.tableView.reloadData()
                if self.repositories.isEmpty { self.empty("No matching repositories", error: nil) }
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.loading = false
                self.tableView.reloadData()
                if self.repositories.isEmpty { self.empty("Could not load repositories", error: error.localizedDescription) } else {
                    self.show(error, retry: { [weak self] in self?.load(reset: false) })
                }
            }
        }
    }
    private func empty(_ title: String, error: String?) {
        var content = UIContentUnavailableConfiguration.empty()
        content.text = title
        content.secondaryText = error ?? (query.isEmpty ? "Repositories available to the server’s GitHub account appear here." : "Try a different name or search by owner.")
        content.image = UIImage(systemName: error == nil ? "magnifyingglass" : "exclamationmark.circle")
        content.imageProperties.tintColor = BloomTheme.accent
        if error != nil {
            content.button.title = "Retry"
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load(reset: true) }
        }
        tableView.backgroundView = UIContentUnavailableView(configuration: content)
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        repositories.isEmpty ? nil : "Choose a repository"
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        repositories.isEmpty ? nil : "Repositories are cloned on your server using its GitHub account."
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { repositories.count + (canLoadMore ? 1 : 0) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == repositories.count {
            let cell = BloomTheme.cell(title: loading ? "Loading more…" : "Load more repositories", symbol: "arrow.down", disclosure: false)
            cell.isUserInteractionEnabled = !loading
            return cell
        }
        let repo = repositories[indexPath.row]
        let isImporting = importingRepository == repo.nameWithOwner
        let cell = BloomTheme.cell(title: repo.nameWithOwner,
            detail: isImporting ? "Cloning on your server…" : repo.description,
            symbol: repo.isPrivate ? "lock.fill" : "book.closed")
        if isImporting {
            let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating()
            cell.accessoryView = progress
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == repositories.count { if !loading { load(reset: false) }; return }
        guard !importing, model.address == origin, let service = model.service else { return }
        let name = repositories[indexPath.row].nameWithOwner
        importing = true; importingRepository = name; tableView.reloadData(); tableView.isUserInteractionEnabled = false; search.searchBar.isUserInteractionEnabled = false
        isModalInPresentation = true; navigationController?.isModalInPresentation = true
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progress)
        title = "Importing repository"
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importing = false; self.importingRepository = nil; self.tableView.reloadData(); self.tableView.isUserInteractionEnabled = true
                self.search.searchBar.isUserInteractionEnabled = true; self.isModalInPresentation = false
                self.navigationController?.isModalInPresentation = false; self.navigationItem.hidesBackButton = false
                self.navigationItem.leftBarButtonItem?.isEnabled = true; self.navigationItem.rightBarButtonItem = nil
                self.title = "Import from GitHub"
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
