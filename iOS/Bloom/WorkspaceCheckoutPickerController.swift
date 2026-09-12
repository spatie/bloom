import UIKit
import BloomClient

final class WorkspaceCheckoutPickerController: UITableViewController, UISearchResultsUpdating {
    private let service: RemoteWorkspaceService
    private let project: RemoteProject
    private let selected: (WorkspaceCheckout?) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private var options: WorkspaceCheckoutOptions?
    private var work: Task<Void, Never>?
    private var isLoading = false
    private var loadFailure: String?
    private var query: String { search.searchBar.text?.lowercased() ?? "" }
    private var requests: [PullRequestListing] { options?.pullRequests.filter { query.isEmpty || "#\($0.number) \($0.title) \($0.headRefName)".lowercased().contains(query) } ?? [] }
    private var branches: [ExistingBranch] { options?.branches.filter { query.isEmpty || $0.name.lowercased().contains(query) } ?? [] }

    init(service: RemoteWorkspaceService, project: RemoteProject, selected: @escaping (WorkspaceCheckout?) -> Void) {
        self.service = service; self.project = project; self.selected = selected; super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(service:project:selected:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Start From"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        search.obscuresBackgroundDuringPresentation = false
        definesPresentationContext = true
        search.searchResultsUpdater = self; search.searchBar.placeholder = "Find a branch or pull request"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "link"), primaryAction: UIAction { [weak self] _ in self?.reference() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Open pull request by number or link"
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        tableView.rowHeight = UITableView.automaticDimension
        load()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { work?.cancel() }
    }
    func updateSearchResults(for searchController: UISearchController) { tableView.reloadData() }
    private func load() {
        work?.cancel(); isLoading = true; loadFailure = nil; tableView.reloadData()
        work = Task { [weak self, service, project] in
            do {
                let result = try await service.checkoutOptions(projectID: project.id)
                guard let self, !Task.isCancelled else { return }
                self.options = result; self.isLoading = false; self.refreshControl?.endRefreshing(); self.tableView.reloadData()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false; self.loadFailure = error.localizedDescription
                self.refreshControl?.endRefreshing(); self.tableView.reloadData()
            }
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : (section == 1 ? max(1, requests.count) : max(1, branches.count))
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "Pull requests" : (section == 2 ? "Existing branches" : nil)
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        if let failure = options?.failure { return failure }
        switch options?.access {
        case .signedOut: return "Sign in to GitHub on the server to browse pull requests."
        case .notInstalled: return "Install GitHub CLI on the server to browse pull requests."
        default: return nil
        }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section != 0, indexPath.section == 1 ? requests.isEmpty : branches.isEmpty {
            let title = isLoading ? "Loading…" : loadFailure != nil ? "Could not load branches and pull requests" : query.isEmpty ? "None available" : "No matches"
            let cell = BloomTheme.cell(title: title, detail: loadFailure ?? (query.isEmpty ? nil : "Try a different search."),
                                      symbol: loadFailure == nil ? "magnifyingglass" : "arrow.clockwise", disclosure: false)
            if isLoading {
                let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating(); cell.accessoryView = progress
            }
            cell.selectionStyle = loadFailure == nil ? .none : .default
            if loadFailure != nil { cell.accessibilityHint = "Double-tap to retry" }
            return cell
        }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 { content.text = "New branch"; content.secondaryText = "A fresh start from " + (project.defaultBranch ?? "the default branch"); content.image = UIImage(systemName: "plus") } else if indexPath.section == 1 {
            let item = requests[indexPath.row]
            content.text = "#\(item.number) \(item.title)"
            content.secondaryText = holder(item)?.note ?? item.qualifiedHead
            content.image = UIImage(systemName: "arrow.triangle.pull")
        } else {
            let item = branches[indexPath.row]
            content.text = item.name; content.secondaryText = item.inUseBy?.note
            content.image = UIImage(systemName: "arrow.triangle.branch")
        }
        content.textProperties.numberOfLines = 2; content.secondaryTextProperties.numberOfLines = 2
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = BloomTheme.accent
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section != 0, indexPath.section == 1 ? requests.isEmpty : branches.isEmpty {
            if loadFailure != nil { load() }
            return
        }
        if indexPath.section == 0 { finish(nil) } else if indexPath.section == 1 {
            let item = requests[indexPath.row]
            if let holder = holder(item) { show(ConnectionRefusal(holder.refusal(branch: item.headRefName))) } else { finish(.pullRequest(item)) }
        } else {
            let item = branches[indexPath.row]
            if let holder = item.inUseBy { show(ConnectionRefusal(holder.refusal(branch: item.name))) } else { finish(.branch(item)) }
        }
    }
    private func holder(_ request: PullRequestListing) -> BranchHolder? {
        request.isCrossRepository ? nil : options?.holders[request.headRefName]
    }
    private func finish(_ value: WorkspaceCheckout?) { selected(value); navigationController?.popViewController(animated: true) }
    private func reference() {
        let alert = UIAlertController(title: "Open pull request", message: "Enter a pull request number or its GitHub URL.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "#123 or GitHub URL"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.keyboardType = .URL }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
            guard let self, let reference = alert.textFields?.first?.text else { return }
            work = Task { [weak self, service, project] in
                do {
                    let result = try await service.resolveReference(reference, projectID: project.id)
                    guard let self, !Task.isCancelled else { return }
                    switch result {
                    case .checkout(let choice): self.finish(choice)
                    case .failure(let message): self.show(ConnectionRefusal(message))
                    }
                } catch { if !Task.isCancelled { self?.show(error) } }
            }
        })
        present(alert, animated: true)
    }
}
