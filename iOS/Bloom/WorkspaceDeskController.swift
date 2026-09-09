import UIKit
import BloomClient

/// The iPad workspace uses native child controllers. Narrow windows present the same tools one at a time.
final class WorkspaceDeskController: UIViewController, UIAdaptivePresentationControllerDelegate, UITabBarDelegate {
    private let connection: MobileConnection
    private let workspace: RemoteWorkspace
    var preferredSessionID: SessionID?
    let review: MobileWorkspaceReview
    private let panes = UIStackView()
    private let compactTabs = UITabBar()
    private var compactTabsHeight: NSLayoutConstraint?
    private var usesCompactTabs = false
    private var browser: PreviewController?
    private var previewTask: Task<Void, Never>?
    private let conversationHost = UIView()
    private let toolHost = UIView()
    private let filesHost = UIView()
    private let conversationRule = UIView()
    private let filesRule = UIView()
    private var conversation: UIViewController?
    private var tool: UIViewController?
    private lazy var files = WorkspaceFilesController(review: review)
    private lazy var reviewController = WorkspaceReviewController(review: review)
    private var conversationWidth: NSLayoutConstraint?
    private var filesWidth: NSLayoutConstraint?
    private var showsConversation = true
    private var showsFiles = true
    private var focusesConversation = false
    private var refreshTask: Task<Void, Never>?
    #if DEBUG
    var fixtureTranscript: RemoteTranscript?
    var fixturePreviewHTML: String?
    #endif

    init(connection: MobileConnection, workspace: RemoteWorkspace) {
        self.connection = connection
        self.workspace = workspace
        review = MobileWorkspaceReview(connection: connection, workspace: workspace)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(connection:workspace:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = workspace.name
        navigationItem.prompt = workspace.branch
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = BloomTheme.background
        view.tintColor = BloomTheme.accent
        panes.axis = .horizontal
        panes.spacing = 0
        panes.alignment = .fill
        panes.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panes)
        compactTabs.translatesAutoresizingMaskIntoConstraints = false
        compactTabs.delegate = self
        compactTabs.tintColor = BloomTheme.accent
        compactTabs.items = [
            UITabBarItem(title: "Conversation", image: UIImage(systemName: "bubble.left.and.bubble.right"), tag: 0),
            UITabBarItem(title: "Preview", image: UIImage(systemName: "safari"), tag: 1),
            UITabBarItem(title: "Review", image: UIImage(systemName: "doc.text.magnifyingglass"), tag: 2),
            UITabBarItem(title: "Files", image: UIImage(systemName: "folder"), tag: 3),
        ]
        compactTabs.selectedItem = compactTabs.items?.first
        view.addSubview(compactTabs)
        compactTabsHeight = compactTabs.heightAnchor.constraint(equalToConstant: 0)
        compactTabsHeight?.isActive = true
        NSLayoutConstraint.activate([
            compactTabs.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            compactTabs.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            compactTabs.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panes.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            panes.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            panes.bottomAnchor.constraint(equalTo: compactTabs.topAnchor),
        ])
        for host in [conversationHost, conversationRule, toolHost, filesRule, filesHost] { panes.addArrangedSubview(host) }
        for rule in [conversationRule, filesRule] {
            rule.backgroundColor = BloomTheme.border
            rule.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
            rule.accessibilityElementsHidden = true
        }
        conversationWidth = conversationHost.widthAnchor.constraint(equalToConstant: 360)
        conversationWidth?.priority = .defaultHigh
        filesWidth = filesHost.widthAnchor.constraint(equalToConstant: 240)
        filesWidth?.priority = .defaultHigh
        filesWidth?.isActive = true
        files.onSelect = { [weak self] path, changed in self?.openFile(path, changed: changed) }
        files.onReviewAll = { [weak self] in self?.openReview(all: true) }
        reviewController.onClose = { [weak self] in self?.closeTool() }
        install(files, in: filesHost)
        review.changed = { [weak self] in
            guard let self else { return }
            self.files.refreshUI()
            self.reviewController.refreshUI()
        }
        openConversation()
        updateToolbar()
        layoutPanes()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connection.isActive { await self.review.refresh() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
        previewTask?.cancel()
        review.cancel()
    }

    private func updateToolbar() {
        let chat = UIBarButtonItem(image: UIImage(systemName: "bubble.left.and.bubble.right"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if self.tool != nil {
                if self.view.safeAreaLayoutGuide.layoutFrame.width < 760 { self.focusesConversation = true } else {
                    self.showsConversation.toggle()
                }
                self.layoutPanes()
            }
        })
        chat.accessibilityLabel = "Show conversation"
        let preview = UIBarButtonItem(image: UIImage(systemName: "safari"), primaryAction: UIAction { [weak self] _ in self?.openPreview() })
        preview.accessibilityLabel = "Open browser preview"
        let changes = UIBarButtonItem(image: UIImage(systemName: "doc.text.magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.openReview(all: true) })
        changes.accessibilityLabel = "Review all changes"
        let inspector = UIBarButtonItem(image: UIImage(systemName: "sidebar.right"), primaryAction: UIAction { [weak self] _ in self?.toggleFiles() })
        inspector.accessibilityLabel = "Show workspace files"
        let menu = UIMenu(children: [
            UIAction(title: "Workspace details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(WorkspaceController(model: self.connection, workspace: self.workspace), animated: true)
            },
            UIMenu(title: "Compare changes", children: [
                UIAction(title: "Branch changes", state: review.scope == .branch ? .on : .off) { [weak self] _ in
                    Task { await self?.review.setScope(.branch); self?.updateToolbar() }
                },
                UIAction(title: "Uncommitted changes", state: review.scope == .uncommitted ? .on : .off) { [weak self] _ in
                    Task { await self?.review.setScope(.uncommitted); self?.updateToolbar() }
                },
            ]),
            UIAction(title: "Refresh files", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                Task { await self?.review.refresh() }
            },
        ])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
        more.accessibilityLabel = "Workspace options"
        navigationItem.rightBarButtonItems = usesCompactTabs ? [more] : [more, inspector, changes, preview, chat]
    }

    private func openConversation() {
        guard conversation == nil else { return }
        let sessions = connection.catalogue?.sessions.filter { $0.workspaceID == workspace.id } ?? []
        if let session = sessions.first(where: { $0.id == preferredSessionID }) ?? sessions.first {
            let content: ConversationController
            #if DEBUG
            if let fixtureTranscript { content = ConversationController(model: connection, session: session, preview: fixtureTranscript) } else {
                content = ConversationController(model: connection, session: session)
            }
            #else
            content = ConversationController(model: connection, session: session)
            #endif
            let wrapped = WorkspacePaneController(title: session.title, image: "bubble.left.and.bubble.right", content: content)
            conversation = wrapped
            install(wrapped, in: conversationHost)
        } else {
            let content = WorkspaceController(model: connection, workspace: workspace)
            conversation = content
            install(content, in: conversationHost)
        }
    }

    func openReview(all: Bool, path: String? = nil) {
        loadViewIfNeeded()
        reviewController.selectedPath = path
        reviewController.showsAllFiles = all
        setTool(reviewController)
    }

    func openFile(_ path: String, changed: Bool) {
        files.selectedPath = path
        dismissFileSheetIfNeeded()
        if changed { openReview(all: false, path: path) } else {
            let source = WorkspaceSourceController(review: review, path: path)
            setTool(WorkspacePaneController(title: (path as NSString).lastPathComponent, image: "doc.text", content: source, onClose: { [weak self] in self?.closeTool() }))
        }
    }

    func openPreview() {
        loadViewIfNeeded()
        if let browser { showBrowser(browser); return }
        #if DEBUG
        if let fixturePreviewHTML {
            showBrowser(PreviewController(previewHTML: fixturePreviewHTML, baseURL: URL(string: "https://preview.bloom.invalid")!))
            return
        }
        #endif
        let alert = UIAlertController(title: "Open preview", message: "Enter the app's local address on your server, or an HTTPS preview address.", preferredStyle: .alert)
        alert.addTextField {
            $0.text = self.workspace.port > 0 ? "http://localhost:\(self.workspace.port)" : ""
            $0.placeholder = "https://preview.example.com"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
            guard let self, let address = alert.textFields?.first?.text else { return }
            previewTask?.cancel()
            previewTask = Task { [weak self] in
                do { try await self?.openPreview(address: address) } catch {
                    guard !Task.isCancelled else { return }
                    self?.show(error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func openPreview(address: String) async throws {
        let preview = try await connection.preparePreview(address: address)
        guard !Task.isCancelled else { preview.close(); throw CancellationError() }
        browser?.closePreview()
        showBrowser(PreviewController(preview: preview))
    }

    #if DEBUG
    var livePreviewReady: Bool { browser?.hasLoadedPage == true }
    var livePreviewFailure: String? { browser?.lastPageFailure }
    var livePreviewTitle: String { browser?.loadedPageTitle ?? "" }
    var liveMessageCount: Int {
        conversation?.children.compactMap { $0 as? ConversationController }.first?.liveMessageCount ?? 0
    }

    /// The live harness uses the production connection and preview path, without entering an alert.
    func openLivePreview(address: String) async throws {
        loadViewIfNeeded()
        try await openPreview(address: address)
    }
    #endif

    private func showBrowser(_ browser: PreviewController) {
        self.browser = browser
        browser.onClose = { [weak self] in self?.closeTool() }
        setTool(browser)
    }

    private func setTool(_ controller: UIViewController) {
        focusesConversation = false
        compactTabs.selectedItem = compactTabs.items?[controller is PreviewController ? 1 : controller is WorkspaceReviewController ? 2 : 3]
        if tool !== controller {
            if let tool { remove(tool) }
            tool = controller
            install(controller, in: toolHost)
        }
        layoutPanes()
    }

    private func closeTool() {
        if tool === browser { browser?.closePreview(); browser = nil }
        compactTabs.selectedItem = compactTabs.items?.first
        if let tool { remove(tool) }
        tool = nil
        showsConversation = true
        layoutPanes()
    }

    private func toggleFiles() {
        if view.safeAreaLayoutGuide.layoutFrame.width >= 960 {
            showsFiles.toggle()
            layoutPanes()
        } else {
            remove(files)
            let navigation = BloomTheme.navigation(files)
            files.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismissFileSheetIfNeeded() })
            navigation.sheetPresentationController?.detents = [.large()]
            navigation.presentationController?.delegate = self
            present(navigation, animated: true)
        }
    }

    private func dismissFileSheetIfNeeded() {
        guard presentedViewController != nil else { return }
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.restoreFiles()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { restoreFiles() }

    private func restoreFiles() {
        files.navigationController?.setViewControllers([], animated: false)
        install(files, in: filesHost)
        layoutPanes()
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        switch item.tag {
        case 0: focusesConversation = true; layoutPanes()
        case 1: openPreview()
        case 2: openReview(all: true)
        default: toggleFiles()
        }
    }

    private func layoutPanes() {
        guard isViewLoaded else { return }
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        let compact = width < 760
        if usesCompactTabs != compact { usesCompactTabs = compact; updateToolbar() }
        compactTabs.isHidden = !compact
        compactTabsHeight?.constant = compact ? 49 + view.safeAreaInsets.bottom : 0
        let hasTool = tool != nil
        let inlineFiles = showsFiles && width >= (hasTool ? 960 : 720) && files.parent === self
        let splitConversation = hasTool && showsConversation && width >= 760
        let compactConversation = width < 760 && focusesConversation
        conversationHost.isHidden = hasTool && !splitConversation && !compactConversation
        conversationRule.isHidden = !splitConversation
        toolHost.isHidden = !hasTool || compactConversation
        filesHost.isHidden = !inlineFiles
        filesRule.isHidden = !inlineFiles
        filesWidth?.constant = width > 1100 ? 240 : 220
        conversationWidth?.isActive = splitConversation
        conversationWidth?.constant = min(420, max(310, (width - (inlineFiles ? 240 : 0)) * 0.44))
    }

    private func install(_ child: UIViewController, in host: UIView) {
        guard child.parent !== self else { return }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: host.topAnchor), child.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), child.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func remove(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    #if DEBUG
    func configurePreview(mode: String) {
        loadViewIfNeeded()
        if mode == "browser" { openPreview() } else if mode == "review" {
            showsConversation = false
            openReview(all: true)
        } else if mode == "files" {
            showsConversation = false
            files.showsAllFiles = true
            openFile("app/Actions/ReplyToTicket.php", changed: false)
        }
    }
    #endif
}
