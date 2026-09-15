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
    private let summary = UILabel()
    private let summaryRow = UIStackView()
    private let reviewButton = UIButton(type: .system)
    private var changedRows: [ChangedFileTreeRow] = []
    private var collapsedChanges: Set<String> = []
    private var filteredCollapsedChanges: Set<String> = []
    private var rows: [FileTreeRowItem] = []
    private var expanded: Set<String> = []
    private var needsSelectionReveal = true
    private var indexedPaths: [String] = []
    private var treeChildren: [String: [FileTreeNode]] = [:]
    private var needle = ""
    private var refreshing: Task<Void, Never>?
    private var minimumRowHeight: CGFloat { 44 }

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
        configureSummary()
        configureTable()
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
            segments.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            segments.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            segments.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: segments.bottomAnchor),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
    }

    private func configureTable() {
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = minimumRowHeight
        table.sectionHeaderTopPadding = 0
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.accessibilityIdentifier = "workspace-file-list"
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: summaryRow.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
    }

    private func configureSummary() {
        summary.font = .preferredFont(forTextStyle: .caption1)
        summary.adjustsFontForContentSizeCategory = true
        summary.textColor = .secondaryLabel
        summary.numberOfLines = 0
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Review All"
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 0)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1)
            return attributes
        }
        reviewButton.configuration = configuration
        reviewButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        reviewButton.accessibilityLabel = "Review all changes"
        reviewButton.setContentHuggingPriority(.required, for: .horizontal)
        reviewButton.addAction(UIAction { [weak self] _ in self?.onReviewAll?() }, for: .touchUpInside)
        summaryRow.axis = .horizontal; summaryRow.alignment = .center; summaryRow.spacing = 8
        summaryRow.addArrangedSubview(summary); summaryRow.addArrangedSubview(reviewButton)
        summaryRow.isLayoutMarginsRelativeArrangement = true
        summaryRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 4, trailing: 14)
        summaryRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryRow)
        NSLayoutConstraint.activate([
            summaryRow.topAnchor.constraint(equalTo: search.bottomAnchor),
            summaryRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func refreshUI() {
        guard isViewLoaded else { return }
        if indexedPaths != review.paths {
            indexedPaths = review.paths
            treeChildren = FileTreeNode.index(indexedPaths)
        }
        revealSelectionIfNeeded()
        let filteredChanges = ChangedFileFilter.apply(to: review.changes, needle: needle)
        if filteredChanges == nil { filteredCollapsedChanges = [] }
        changedRows = ChangedFileTree.rows(from: ChangedFileTree.build(from: filteredChanges ?? review.changes),
                                           collapsed: needle.isEmpty ? collapsedChanges : filteredCollapsedChanges)
        if let filtered = FileTreeFilter.apply(to: treeChildren, needle: needle) {
            rows = FileTreeRowItem.flatten(children: filtered.children, expanded: expanded.union(filtered.open))
        } else {
            rows = FileTreeRowItem.flatten(children: treeChildren, expanded: expanded)
        }
        reviewButton.isEnabled = !review.changes.isEmpty
        reviewButton.isHidden = showsAllFiles
        summary.text = showsAllFiles ? "\(review.paths.count) files" : "\(review.changes.count) changed " + (review.changes.count == 1 ? "file" : "files")
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
        let isEmpty = showsAllFiles ? rows.isEmpty : changedRows.isEmpty
        updateRefreshNotice(isEmpty: isEmpty)
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

    private func updateRefreshNotice(isEmpty: Bool) {
        guard !isEmpty, let error = review.error else { table.tableHeaderView = nil; return }
        let label = BloomTheme.label("Could not refresh. " + error, style: .footnote, secondary: true)
        let button = UIButton(type: .system)
        button.setTitle("Retry", for: .normal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.retry() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 8
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        let width = max(100, table.bounds.width)
        let size = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        stack.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        table.tableHeaderView = stack
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
        let index = showsAllFiles ? rows.firstIndex { $0.node.path == selectedPath } : changedRows.firstIndex { $0.node.path == selectedPath }
        if let index {
            table.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
        } else if let selection = table.indexPathForSelectedRow {
            table.deselectRow(at: selection, animated: false)
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        needle = FileNeedle.canonical(searchText)
        refreshUI()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showsAllFiles ? rows.count : changedRows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file") ?? UITableViewCell(style: .default, reuseIdentifier: "file")
        cell.backgroundColor = .clear
        cell.accessoryView = nil
        let minimumHeight = minimumRowHeight
        if showsAllFiles {
            let row = rows[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                BloomFileRow(path: row.node.path, isDirectory: row.node.isDirectory)
                    .font(.subheadline).frame(minHeight: minimumHeight)
            }.margins(.vertical, 0).margins(.leading, 10 + CGFloat(min(row.depth, 8)) * 10).margins(.trailing, 10)
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
            let row = changedRows[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                if let file = row.node.file {
                    BloomFileRow(file: file, showsDirectory: false).font(.subheadline).frame(minHeight: minimumHeight)
                } else {
                    BloomFileRow {
                        BloomFileIcon(isDirectory: true)
                    } name: {
                        Text(verbatim: row.node.name).font(.subheadline.weight(.medium))
                    } trailing: {
                        EmptyView()
                    }.font(.subheadline).frame(minHeight: minimumHeight)
                }
            }.margins(.vertical, 0).margins(.leading, 10 + CGFloat(min(row.depth, 8)) * 10).margins(.trailing, 10)
            if row.node.isFolder {
                let closed = (needle.isEmpty ? collapsedChanges : filteredCollapsedChanges).contains(row.node.path)
                let indicator = UIImageView(image: UIImage(systemName: closed ? "chevron.right" : "chevron.down"))
                indicator.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
                indicator.tintColor = .tertiaryLabel
                cell.accessoryView = indicator
                cell.accessibilityHint = closed ? "Expand folder" : "Collapse folder"
            } else { cell.accessibilityHint = "Review changes" }
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
            let node = changedRows[indexPath.row].node
            if node.isFolder {
                if needle.isEmpty {
                    if !collapsedChanges.insert(node.path).inserted { collapsedChanges.remove(node.path) }
                } else {
                    if !filteredCollapsedChanges.insert(node.path).inserted { filteredCollapsedChanges.remove(node.path) }
                }
                refreshUI()
                return
            }
            selectedPath = node.path
            onSelect?(node.path, true)
        }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let path = showsAllFiles ? rows[indexPath.row].node.path : changedRows[indexPath.row].node.path
        let folder = showsAllFiles ? rows[indexPath.row].node.isDirectory : changedRows[indexPath.row].node.isFolder
        return UIContextMenuConfiguration(identifier: path as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIAction(title: "Copy path", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = path
            }]
            if !folder {
                if self.review.changes.contains(where: { $0.path == path }) {
                    actions.append(UIAction(title: "Review changes", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                        self?.selectedPath = path
                        self?.onSelect?(path, true)
                    })
                }
                if self.review.paths.contains(path) {
                    actions.append(UIAction(title: "Open file", image: UIImage(systemName: "doc.text")) { [weak self] _ in
                        self?.selectedPath = path
                        self?.onSelect?(path, false)
                    })
                }
            }
            return UIMenu(children: actions)
        }
    }

    #if DEBUG
    /// Exercise disclosure and filtered navigation through the production table adapter.
    func verifyLiveTree() throws -> Int {
        refreshUI()
        let count = changedRows.filter { $0.node.isFolder }.count
        guard let index = changedRows.firstIndex(where: { $0.node.isFolder }) else { return count }
        let folder = changedRows[index].node
        let original = changedRows.map(\.id)
        tableView(table, didSelectRowAt: IndexPath(row: index, section: 0))
        guard changedRows.count < original.count else { throw ConnectionFailure("Folder disclosure did not hide its children.") }
        searchBar(search, textDidChange: folder.path)
        guard !changedRows.isEmpty else { throw ConnectionFailure("Filtering could not find the closed folder.") }
        searchBar(search, textDidChange: "")
        guard changedRows.count < original.count else { throw ConnectionFailure("Filtering discarded folder disclosure state.") }
        guard let closedIndex = changedRows.firstIndex(where: { $0.id == folder.id }) else { throw ConnectionFailure("Closed folder disappeared.") }
        tableView(table, didSelectRowAt: IndexPath(row: closedIndex, section: 0))
        guard changedRows.map(\.id) == original else { throw ConnectionFailure("Reopening the folder did not restore its children.") }
        return count
    }
    #endif

}
