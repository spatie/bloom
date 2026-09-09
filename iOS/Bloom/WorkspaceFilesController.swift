import UIKit
import SwiftUI
import BloomClient
import BloomUI

/// UIKit owns the inspector list. Its tree, filtering and file-row content are shared with Mac.
final class WorkspaceFilesController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    let review: MobileWorkspaceReview
    var onSelect: ((String, Bool) -> Void)?
    var onReviewAll: (() -> Void)?
    var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue else { return }
            needsSelectionReveal = true
            if isViewLoaded { refreshUI() }
        }
    }
    var showsAllFiles = false {
        didSet {
            guard isViewLoaded else { return }
            segments.selectedSegmentIndex = showsAllFiles ? 1 : 0
            if showsAllFiles { needsSelectionReveal = true }
            refreshUI()
        }
    }

    private let table = UITableView(frame: .zero, style: .plain)
    private let segments = UISegmentedControl(items: ["Changes", "Files"])
    private let search = UISearchBar()
    private let toolbar = UIToolbar()
    private var visibleChanges: [ChangedFile] = []
    private var rows: [FileTreeRowItem] = []
    private var expanded: Set<String> = []
    private var needsSelectionReveal = true
    private var indexedPaths: [String] = []
    private var treeChildren: [String: [FileTreeNode]] = [:]
    private var needle = ""
    private var refreshing: Task<Void, Never>?
    private lazy var reviewItem = UIBarButtonItem(title: "Review all changes", image: UIImage(systemName: "doc.text.magnifyingglass"),
                                                 primaryAction: UIAction { [weak self] _ in self?.onReviewAll?() })

    init(review: MobileWorkspaceReview) {
        self.review = review
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(review:)") }
    deinit { refreshing?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Files"
        view.backgroundColor = BloomTheme.panel
        view.tintColor = BloomTheme.accent
        configureHeader()
        configureTable()
        configureToolbar()
        refreshUI()
    }

    private func configureHeader() {
        segments.selectedSegmentIndex = showsAllFiles ? 1 : 0
        segments.accessibilityLabel = "File list"
        segments.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showsAllFiles = segments.selectedSegmentIndex == 1
        }, for: .valueChanged)
        segments.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segments)
        search.searchBarStyle = .minimal
        search.placeholder = "Filter files"
        search.delegate = self
        search.autocapitalizationType = .none
        search.autocorrectionType = .no
        search.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(search)
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            segments.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            segments.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            segments.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            search.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 4),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
    }

    private func configureTable() {
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.sectionHeaderTopPadding = 8
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.accessibilityIdentifier = "workspace-file-list"
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: search.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureToolbar() {
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = BloomTheme.panel
        appearance.shadowColor = BloomTheme.border
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), reviewItem, UIBarButtonItem(systemItem: .flexibleSpace)]
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: table.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    func refreshUI() {
        guard isViewLoaded else { return }
        if indexedPaths != review.paths {
            indexedPaths = review.paths
            treeChildren = FileTreeNode.index(indexedPaths)
        }
        revealSelectionIfNeeded()
        visibleChanges = review.changes.filter { needle.isEmpty || $0.path.localizedCaseInsensitiveContains(needle) }
        if let filtered = FileTreeFilter.apply(to: treeChildren, needle: needle) {
            rows = FileTreeRowItem.flatten(children: filtered.children, expanded: expanded.union(filtered.open))
        } else {
            rows = FileTreeRowItem.flatten(children: treeChildren, expanded: expanded)
        }
        reviewItem.isEnabled = !review.changes.isEmpty
        table.reloadData()
        updateEmptyState()
        updateSelection()
    }

    private func revealSelectionIfNeeded() {
        guard showsAllFiles, needsSelectionReveal, let selectedPath,
              indexedPaths.contains(selectedPath) else { return }
        let components = selectedPath.split(separator: "/")
        var parent = ""
        for component in components.dropLast() {
            parent = parent.isEmpty ? String(component) : parent + "/" + String(component)
            expanded.insert(parent)
        }
        needsSelectionReveal = false
    }

    private func updateEmptyState() {
        let isEmpty = showsAllFiles ? rows.isEmpty : visibleChanges.isEmpty
        guard isEmpty else { table.backgroundView = nil; return }
        var configuration: UIContentUnavailableConfiguration
        if review.isLoading && !review.hasLoaded {
            configuration = .loading()
            configuration.text = "Loading files"
        } else {
            configuration = .empty()
            if let error = review.error {
                configuration.image = UIImage(systemName: "wifi.exclamationmark")
                configuration.text = "Files unavailable"
                configuration.secondaryText = error
                configuration.button.title = "Try again"
                configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.retry() }
            } else if !needle.isEmpty {
                configuration.image = UIImage(systemName: "doc.text.magnifyingglass")
                configuration.text = "No matching files"
                configuration.secondaryText = "Try a different name or path."
            } else {
                configuration.image = UIImage(systemName: showsAllFiles ? "folder" : "checkmark.circle")
                configuration.text = showsAllFiles ? "No files yet" : "No changes yet"
                configuration.secondaryText = showsAllFiles ? "Workspace files will appear here." : "Changes from your agent will appear here."
            }
        }
        table.backgroundView = UIContentUnavailableView(configuration: configuration)
    }

    private func retry() {
        refreshing?.cancel()
        let review = review
        refreshing = Task { [weak self] in
            await review.refresh()
            guard !Task.isCancelled else { return }
            self?.refreshUI()
        }
    }

    private func updateSelection() {
        let index = showsAllFiles ? rows.firstIndex { $0.node.path == selectedPath } : visibleChanges.firstIndex { $0.path == selectedPath }
        if let index {
            table.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
        } else if let selection = table.indexPathForSelectedRow {
            table.deselectRow(at: selection, animated: false)
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshUI()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showsAllFiles ? rows.count : visibleChanges.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        showsAllFiles ? "Workspace files" : "\(review.changes.count) changed files"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file") ?? UITableViewCell(style: .default, reuseIdentifier: "file")
        cell.backgroundColor = .clear
        cell.accessoryView = nil
        if showsAllFiles {
            let row = rows[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                BloomFileRow(path: row.node.path, isDirectory: row.node.isDirectory)
                    .frame(minHeight: 44)
            }.margins(.vertical, 2).margins(.leading, 14 + CGFloat(min(row.depth, 8)) * 12).margins(.trailing, 10)
            if row.node.isDirectory {
                let isExpanded = expanded.contains(row.node.path) || !needle.isEmpty
                let indicator = UIImageView(image: UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right"))
                indicator.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
                indicator.tintColor = .tertiaryLabel
                cell.accessoryView = indicator
                cell.accessibilityHint = isExpanded ? "Collapse folder" : "Expand folder"
            } else {
                cell.accessibilityHint = "Open file"
            }
        } else {
            let file = visibleChanges[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                BloomFileRow(file: file).frame(minHeight: 44)
            }.margins(.vertical, 4).margins(.horizontal, 14)
            cell.accessibilityHint = "Review changes"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if showsAllFiles {
            let node = rows[indexPath.row].node
            if node.isDirectory {
                if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                refreshUI()
                return
            }
            selectedPath = node.path
            onSelect?(node.path, false)
        } else {
            let path = visibleChanges[indexPath.row].path
            selectedPath = path
            onSelect?(path, true)
        }
    }
}
