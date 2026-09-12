import UIKit
import SwiftUI
import BloomClient
import BloomUI

/// Native table reuse keeps an all-files review proportional to the visible files.
final class WorkspaceReviewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let review: MobileWorkspaceReview
    private let table = UITableView(frame: .zero, style: .plain)
    private let mode = UISegmentedControl(items: ["All files", "Selected file"])
    private let summary = UILabel()
    private let summaryContainer = UIStackView()
    private let retry = UIButton(type: .system)
    private var displayed: [ChangedFile] = []
    private var renderedDiffs: [String: FileDiff] = [:]
    private var renderedErrors: [String: String] = [:]
    var selectedPath: String? { didSet { if isViewLoaded { refreshUI() } } }
    var showsAllFiles = true { didSet { if isViewLoaded { mode.selectedSegmentIndex = showsAllFiles ? 0 : 1; refreshUI() } } }
    var onClose: (() -> Void)?
    var isReviewVisible = false {
        didSet {
            guard isReviewVisible != oldValue else { return }
            if isReviewVisible { refreshUI() } else {
                review.setVisiblePaths([])
                renderedDiffs = [:]
                renderedErrors = [:]
            }
        }
    }

    init(review: MobileWorkspaceReview) { self.review = review; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(review:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        mode.accessibilityLabel = "Review scope"
        mode.selectedSegmentIndex = showsAllFiles ? 0 : 1
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.showsAllFiles = self.mode.selectedSegmentIndex == 0
        }, for: .valueChanged)
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(customView: mode), .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in self?.onClose?() })]
        toolbar.items?.last?.accessibilityLabel = "Close review"
        toolbar.tintColor = BloomTheme.accent
        summary.font = .preferredFont(forTextStyle: .caption1)
        summary.adjustsFontForContentSizeCategory = true
        summary.textColor = BloomTheme.secondary
        summary.numberOfLines = 0
        retry.setTitle("Retry", for: .normal)
        retry.setContentHuggingPriority(.required, for: .horizontal)
        retry.addAction(UIAction { [weak self] _ in Task { await self?.review.refresh() } }, for: .touchUpInside)
        retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        summaryContainer.addArrangedSubview(summary)
        summaryContainer.addArrangedSubview(retry)
        summaryContainer.spacing = 12
        summaryContainer.alignment = .center
        summaryContainer.isLayoutMarginsRelativeArrangement = true
        summaryContainer.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = BloomTheme.background
        table.separatorStyle = .none
        table.estimatedRowHeight = 360
        table.register(UITableViewCell.self, forCellReuseIdentifier: "diff")
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { await self.review.refresh(); self.table.refreshControl?.endRefreshing() }
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [toolbar, summaryContainer, table])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
        ])
        refreshUI()
    }

    func refreshUI() {
        guard isViewLoaded, isReviewVisible else { return }
        let previous = displayed
        let path = selectedPath.flatMap { selected in review.changes.contains { $0.path == selected } ? selected : nil } ?? review.changes.first?.path
        displayed = showsAllFiles ? review.changes : review.changes.filter { $0.path == path }
        let count = review.changes.count
        let additions = review.changes.reduce(0) { $0 + $1.additions }
        let deletions = review.changes.reduce(0) { $0 + $1.deletions }
        let totals = NSMutableAttributedString(string: "\(count) " + (count == 1 ? "changed file" : "changed files"),
            attributes: [.foregroundColor: UIColor.secondaryLabel])
        totals.append(NSAttributedString(string: "   +\(additions)", attributes: [.foregroundColor: BloomTheme.colour(PaletteInk.accent)]))
        totals.append(NSAttributedString(string: "  −\(deletions)", attributes: [.foregroundColor: BloomTheme.colour(PaletteInk.negative)]))
        summary.attributedText = totals
        summary.accessibilityLabel = "\(count) changed files, \(additions) additions, \(deletions) deletions"
        summaryContainer.isHidden = displayed.isEmpty
        mode.isEnabled = !review.changes.isEmpty
        retry.isHidden = review.error == nil
        if let error = review.error {
            summary.text = "Could not refresh. " + error
            summary.accessibilityLabel = summary.text
        }
        if displayed.isEmpty {
            var empty = !review.hasLoaded && review.error == nil ? UIContentUnavailableConfiguration.loading() : .empty()
            if review.hasLoaded || review.error != nil {
                empty.image = UIImage(systemName: review.error == nil ? "checkmark.circle" : "wifi.exclamationmark")
            }
            empty.text = review.error == nil ? (review.hasLoaded ? "No changes yet" : "Loading changes") : "Could not load changes"
            empty.secondaryText = review.error ?? "Changes made in this workspace appear here."
            if review.error != nil {
                empty.button.title = "Retry"
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    Task { await self?.review.refresh() }
                }
            }
            table.backgroundView = UIContentUnavailableView(configuration: empty)
        } else { table.backgroundView = nil }
        if previous.map(\.path) != displayed.map(\.path) { table.reloadData() } else {
            let changed = (table.indexPathsForVisibleRows ?? []).filter { index in
                guard displayed.indices.contains(index.row) else { return false }
                let path = displayed[index.row].path
                return renderedDiffs[path] != review.diffs[path] || renderedErrors[path] != review.errors[path]
            }
            if !changed.isEmpty { table.reconfigureRows(at: changed) }
        }
        updateVisiblePaths()
        for index in table.indexPathsForVisibleRows ?? [] where displayed.indices.contains(index.row) {
            review.loadDiff(path: displayed[index.row].path)
        }
    }

    #if DEBUG
    var liveReviewReady: Bool {
        let paths = (table.indexPathsForVisibleRows ?? []).compactMap { displayed.indices.contains($0.row) ? displayed[$0.row].path : nil }
        return isReviewVisible && !paths.isEmpty && paths.allSatisfy { review.diffs[$0] != nil }
    }
    #endif

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let file = displayed[indexPath.row]
        renderedDiffs[file.path] = review.diffs[file.path]
        renderedErrors[file.path] = review.errors[file.path]
        let cell = tableView.dequeueReusableCell(withIdentifier: "diff", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        if let diff = review.diffs[file.path] {
            cell.contentConfiguration = UIHostingConfiguration {
                BloomDiffFile(file: diff, scrollsVertically: false).padding(8).id(file.path)
            }.margins(.all, 0)
        } else if let error = review.errors[file.path] {
            cell.contentConfiguration = UIHostingConfiguration {
                VStack(alignment: .leading, spacing: 12) {
                    BloomFileRow(file: file)
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Retry") { [weak review] in review?.retry(path: file.path) }
                        .buttonStyle(.bordered)
                }.padding(16)
            }.margins(.all, 0)
        } else {
            cell.contentConfiguration = UIHostingConfiguration {
                VStack(alignment: .leading, spacing: 16) {
                    BloomFileRow(file: file)
                    ProgressView("Loading diff").font(.callout)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.margins(.all, 0)
        }
        return cell
    }
    private func updateVisiblePaths(including index: IndexPath? = nil, excluding removed: IndexPath? = nil) {
        guard isReviewVisible else { review.setVisiblePaths([]); return }
        var indices = Set(table.indexPathsForVisibleRows ?? [])
        if let index { indices.insert(index) }
        if let removed { indices.remove(removed) }
        let paths = Set(indices.compactMap { displayed.indices.contains($0.row) ? displayed[$0.row].path : nil })
        review.setVisiblePaths(paths)
        renderedDiffs = renderedDiffs.filter { paths.contains($0.key) }
        renderedErrors = renderedErrors.filter { paths.contains($0.key) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        review.setVisiblePaths([])
        renderedDiffs = [:]
        renderedErrors = [:]
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        updateVisiblePaths(including: indexPath)
        guard isReviewVisible, displayed.indices.contains(indexPath.row) else { return }
        review.loadDiff(path: displayed[indexPath.row].path)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let current = tableView.cellForRow(at: indexPath), current !== cell { return }
        updateVisiblePaths(excluding: indexPath)
    }
}
