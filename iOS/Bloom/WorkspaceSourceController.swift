import UIKit
import SwiftUI
import BloomClient
import BloomUI

/// A read-only source tab uses the same server file request and code rendering as the other clients.
final class WorkspaceSourceController: UIViewController {
    private let review: MobileWorkspaceReview
    private let path: String
    private var loading: Task<Void, Never>?
    private var content: UIViewController?
    private let scroll = UIScrollView()
    private let actions = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: []))
    private var sourceText: String?

    init(review: MobileWorkspaceReview, path: String) {
        self.review = review
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = (path as NSString).lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("Use init(review:path:)") }
    deinit { loading?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        view.tintColor = BloomTheme.accent
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = BloomTheme.background
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "workspace-source"
        actions.accessibilityLabel = "File actions"
        navigationItem.rightBarButtonItems = [actions]
        view.addSubview(scroll)
        scroll.refreshControl = UIRefreshControl()
        scroll.refreshControl?.addAction(UIAction { [weak self] _ in self?.loadFile() }, for: .valueChanged)
        updateActions()
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        loadFile()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if content == nil && loading == nil { loadFile() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loading?.cancel()
        loading = nil
    }

    private func loadFile() {
        loading?.cancel()
        var state = UIContentUnavailableConfiguration.loading()
        state.text = "Loading file"
        contentUnavailableConfiguration = state
        let review = review
        let path = path
        loading = Task { [weak self] in
            defer { self?.scroll.refreshControl?.endRefreshing() }
            do {
                let file = try await review.readFile(path: path)
                guard !Task.isCancelled else { return }
                guard review.service != nil else {
                    throw ConnectionFailure("Reconnect to this server to read the file.")
                }
                self?.loading = nil
                self?.showFile(file.text)
            } catch {
                guard !Task.isCancelled else { return }
                self?.loading = nil
                self?.showFailure(error.localizedDescription)
            }
        }
    }

    private func showFile(_ text: String) {
        contentUnavailableConfiguration = nil
        sourceText = text
        updateActions()
        content?.willMove(toParent: nil)
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        let path = path
        let host = UIHostingController(rootView:
            BloomCodeBlock(code: text, language: Language.detect(path: path)).padding(12))
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        scroll.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        host.didMove(toParent: self)
        content = host
    }

    private func updateActions() {
        actions.menu = UIMenu(title: path, children: [
            UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = self?.path
            },
            UIAction(title: "Copy File Contents", image: UIImage(systemName: "doc.text"),
                     attributes: sourceText == nil ? .disabled : []) { [weak self] _ in
                guard let text = self?.sourceText else { return }
                UIPasteboard.general.string = text
            },
            UIAction(title: "Reload File", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.loadFile() }
        ])
    }

    private func showFailure(_ message: String) {
        var state = UIContentUnavailableConfiguration.empty()
        state.image = UIImage(systemName: "doc.badge.ellipsis")
        state.text = "File couldn’t load"
        state.secondaryText = message
        state.button.title = "Try Again"
        state.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.loadFile() }
        contentUnavailableConfiguration = state
    }
}
