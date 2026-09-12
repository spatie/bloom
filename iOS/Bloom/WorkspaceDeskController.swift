import UIKit
import BloomClient

/// The iPad workspace uses native child controllers. Narrow windows present the same tools one at a time.
final class WorkspaceDeskController: UIViewController, UIAdaptivePresentationControllerDelegate, UITabBarDelegate {
    private let connection: MobileConnection
    private let workspace: RemoteWorkspace
    var preferredSessionID: SessionID?
    let review: MobileWorkspaceReview
    private let panes = UIStackView()
    private let connectionStatus = MobileConnectionStatusView()
    private var connectionObserver: UUID?
    private var connectedGeneration: Int?
    private let compactTabs = UITabBar()
    private var compactTabsHeight: NSLayoutConstraint?
    private var usesCompactTabs = false
    private var compactToolID: String?
    private var browser: PreviewController?
    private var previewTask: Task<Void, Never>?
    private var previewPreparations: Set<UUID> = []
    private var previewNavigationRequests: [String: UUID] = [:]
    private let conversationHost = UIView()
    private let toolHost = UIView()
    private let filesHost = UIView()
    private let conversationRule = UIView()
    private let filesRule = UIView()
    private var conversation: UIViewController?
    private var tool: UIViewController?
    private let deck = WorkspaceToolDeckController()
    private var uiSession: RemoteUIClientSession?
    private var notes: WorkspaceNotesController?
    private var primaryInDeck = false
    private lazy var files = WorkspaceFilesController(review: review)
    private lazy var reviewController = WorkspaceReviewController(review: review)
    private var conversationWidth: NSLayoutConstraint?
    private var filesWidth: NSLayoutConstraint?
    private var showsConversation = true
    private var showsFiles = false
    private var filesButton: UIBarButtonItem?
    private var filesNavigation: UINavigationController?
    private var isDismissingFiles = false
    private var conversationActions: [UIBarButtonItem] = []
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
        navigationItem.prompt = nil
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = BloomTheme.background
        view.tintColor = BloomTheme.accent
        panes.axis = .horizontal
        panes.spacing = 0
        panes.alignment = .fill
        panes.translatesAutoresizingMaskIntoConstraints = false
        connectionStatus.onRetry = { [weak self] in self?.connection.retryConnection() }
        connectionStatus.update(connection.recovery, canRetry: connection.canRetryConnection)
        let content = UIStackView(arrangedSubviews: [connectionStatus, panes]); content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
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
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: compactTabs.topAnchor),
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
        deck.onEmpty = { [weak self] in self?.removeDeck() }
        deck.onSelection = { [weak self] in self?.focusesConversation = false; self?.updateToolbar(); self?.layoutPanes() }
        deck.onNewPane = { [weak self] kind, split in self?.requestNewPane(kind: kind, split: split) }
        deck.onRename = { [weak self] pane in self?.requestRename(pane) }
        deck.onClosePane = { [weak self] pane in self?.requestClosePane(pane) }
        deck.onEndTerminal = { [weak self] pane in
            guard let self, let terminal = pane.content as? WorkspaceTerminalController else { return }
            Task {
                do { try await connection.closeTerminal(workspaceID: workspace.id, name: terminal.terminalName); deck.close(pane) } catch { show(error) }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: UIScene.willDeactivateNotification, object: nil)
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
        connectionObserver = connection.observe { [weak self] in self?.connectionChanged() }
        connectionChanged()
        attachUI()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connection.canSend { self.attachUI(); await self.review.refresh() } else { self.uiSession?.stop() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let connectionObserver { connection.removeObserver(connectionObserver) }
        connectionObserver = nil
        refreshTask?.cancel()
        refreshTask = nil
        previewTask?.cancel()
        uiSession?.stop()
        deck.suspendTerminals()
        review.cancel()
    }

    private func connectionChanged() {
        connectionStatus.update(connection.recovery, canRetry: connection.canRetryConnection)
        if connection.canSend, connectedGeneration != connection.generation {
            connectedGeneration = connection.generation
            uiSession?.stop(); uiSession = nil
            attachUI()
        } else if !connection.canSend { uiSession?.stop(); deck.suspendTerminals() }
    }

    private func updateToolbar() {
        let openingPreview = !previewPreparations.isEmpty
        let preview = UIBarButtonItem(title: openingPreview ? "Opening…" : "Preview", primaryAction: UIAction { [weak self] _ in self?.openPreview() })
        preview.accessibilityLabel = openingPreview ? "Opening browser preview" : "Open browser preview"
        preview.isEnabled = !openingPreview
        compactTabs.items?[1].title = openingPreview ? "Opening…" : "Preview"
        compactTabs.items?[1].isEnabled = !openingPreview
        let inspector = UIBarButtonItem(title: "Files", primaryAction: UIAction { [weak self] _ in self?.toggleFiles() })
        inspector.accessibilityLabel = "Show files and changes"
        filesButton = inspector
        let onlyConversation = primaryInDeck ? deck.focusesSinglePane && deck.selectedPane?.content === conversation : focusesConversation || tool == nil
        let sideBySide = primaryInDeck ? !deck.focusesSinglePane : tool != nil && showsConversation && !focusesConversation
        let toolName = deck.selectedPane?.kind == "browser" ? "Preview" : deck.selectedPane?.kind == "review" ? "Review"
            : deck.selectedPane?.kind == "source" ? "File" : "Current Pane"
        let viewMenu = UIMenu(title: "Workspace view", options: .singleSelection, children: [
            UIAction(title: "Conversation", image: UIImage(systemName: "text.bubble"),
                     state: onlyConversation ? .on : .off) { [weak self] _ in
                self?.focusConversation(); self?.updateToolbar()
            },
            UIAction(title: "Side by Side", image: UIImage(systemName: "rectangle.split.2x1"),
                     attributes: tool == nil ? .disabled : [],
                     state: sideBySide ? .on : .off) { [weak self] _ in
                self?.deck.focusesSinglePane = false
                self?.showsConversation = true; self?.focusesConversation = false; self?.layoutPanes(); self?.updateToolbar()
            },
            UIAction(title: toolName + " Only", image: UIImage(systemName: "rectangle"),
                     attributes: tool == nil ? .disabled : [],
                     state: tool != nil && !onlyConversation && !sideBySide ? .on : .off) { [weak self] _ in
                self?.deck.focusesSinglePane = true
                self?.showsConversation = false; self?.focusesConversation = false; self?.layoutPanes(); self?.updateToolbar()
            },
        ])
        let layout = UIBarButtonItem(title: "View", menu: viewMenu)
        layout.accessibilityLabel = "Workspace layout"
        let menu = UIMenu(children: [
            UIMenu(title: "Tabs and panes", children: deck.paneActionsMenu.children),
            UIMenu(title: "Open tabs", children: (tabsJSON()["tabs"]?.arrayValue ?? []).compactMap { tab -> UIAction? in
                guard let number = tab["tab"]?.intValue, let title = tab["title"]?.stringValue else { return nil }
                return UIAction(title: title, state: tab["active"]?.boolValue == true ? .on : .off) { [weak self] _ in
                    Task { _ = await self?.handleUI(.init(name: "workspace_tab_select", arguments: .object(["tab": .integer(number)]))) }
                }
            }),
            UIAction(title: "Review All Changes", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in self?.openReview(all: true) },
            UIAction(title: "Agent UI tools", image: UIImage(systemName: "rectangle.connected.to.line.below")) { [weak self] _ in self?.showAgentUIStatus() },
            UIAction(title: "Workspace notes", image: UIImage(systemName: PaneGlyph.notes)) { [weak self] _ in self?.openNotes() },
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
        navigationItem.titleMenuProvider = { _ in menu }
        navigationItem.rightBarButtonItems = conversationActions + (usesCompactTabs ? [] : [layout, inspector, preview])
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
            content.onOpenSession = { [weak self] session in self?.replaceConversation(with: session) }
            let wrapped = WorkspacePaneController(title: session.title, image: "bubble.left.and.bubble.right", content: content)
            conversation = wrapped
            install(wrapped, in: conversationHost)
        } else {
            let content = WorkspaceController(model: connection, workspace: workspace)
            conversation = content
            install(content, in: conversationHost)
        }
    }

    private func replaceConversation(with session: RemoteSession) {
        if primaryInDeck, let pane = deck.allPanes.first(where: { $0.content === conversation }) {
            let content = ConversationController(model: connection, session: session)
            let wrapped = WorkspacePaneController(title: session.title, image: PaneGlyph.chat, content: content)
            deck.replace(pane, content: wrapped)
            pane.sessionID = session.id
            deck.rename(pane, title: session.title)
            conversation = wrapped; preferredSessionID = session.id
            configure(pane)
            return
        }
        if let conversation { remove(conversation) }
        let content = ConversationController(model: connection, session: session)
        content.onOpenSession = { [weak self] session in self?.replaceConversation(with: session) }
        let wrapped = WorkspacePaneController(title: session.title, image: "bubble.left.and.bubble.right", content: content)
        conversation = wrapped
        preferredSessionID = session.id
        install(wrapped, in: conversationHost)
        focusesConversation = true
        layoutPanes()
        Task { try? await connection.refresh() }
    }

    func openReview(all: Bool, path: String? = nil) {
        loadViewIfNeeded()
        dismissFileSheetIfNeeded()
        reviewController.selectedPath = path
        reviewController.showsAllFiles = all
        setTool(reviewController)
        deck.selectedPane?.path = path
    }

    func openFile(_ path: String, changed: Bool) {
        files.selectedPath = path
        if changed { openReview(all: false, path: path) } else {
            dismissFileSheetIfNeeded()
            if let pane = deck.allPanes.first(where: { $0.kind == "source" && $0.path == path }) {
                deck.selectPane(pane)
                showDeck()
                return
            }
            let source = WorkspaceSourceController(review: review, path: path)
            let title = (path as NSString).lastPathComponent
            let content = WorkspacePaneController(title: title, image: "doc.text", content: source)
            let pane = WorkspaceToolPane(kind: "source", title: title, content: content)
            pane.path = path
            configure(pane)
            deck.add(pane)
            showDeck()
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

    private func preparePreview(address: String) async throws -> MobilePreviewLease {
        let preparation = UUID()
        previewPreparations.insert(preparation)
        updateToolbar()
        defer { previewPreparations.remove(preparation); updateToolbar() }
        return try await connection.preparePreview(address: address)
    }

    private func openPreview(address: String) async throws {
        let preview = try await preparePreview(address: address)
        guard !Task.isCancelled else { preview.close(); throw CancellationError() }
        showBrowser(PreviewController(preview: preview))
    }

    #if DEBUG
    func focusLiveConversation() { focusConversation() }
    func showLiveFiles() { toggleFiles() }
    var liveReviewReady: Bool { reviewController.liveReviewReady }
    var liveReviewFailure: String? { review.error ?? review.errors.values.first }
    var liveFilesReady: Bool { review.hasLoaded }
    func verifyLiveTree() throws -> Int { try files.verifyLiveTree() }
    func showLiveOptions() async throws {
        guard let content = conversation?.children.compactMap({ $0 as? ConversationController }).first else {
            throw ConnectionFailure("No conversation is open.")
        }
        try await content.showLiveOptions()
    }
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
        setTool(browser)
    }

    private func setTool(_ controller: UIViewController) {
        focusesConversation = false
        if let pane = deck.allPanes.first(where: { $0.content === controller }) { deck.selectPane(pane) } else {
            let kind = controller is PreviewController ? "browser" : controller is WorkspaceTerminalController ? "terminal" : controller is WorkspaceNotesController ? "notes" : "review"
            let base = kind == "browser" ? PaneNaming.browser : kind == "terminal" ? PaneNaming.terminal : kind == "notes" ? "Notes" : "Review"
            let title = PaneNaming.nextTitle(base: base, taken: deck.allPanes.filter { $0.kind == kind }.map(\.title))
            let pane = WorkspaceToolPane(kind: kind, title: title, content: controller)
            configure(pane)
            deck.add(pane)
        }
        showDeck()
    }

    private func showDeck() {
        if tool !== deck {
            if let tool { remove(tool) }
            tool = deck
            install(deck, in: toolHost)
        }
        layoutPanes()
    }

    private func removeDeck() {
        compactTabs.selectedItem = compactTabs.items?.first
        if let tool { remove(tool) }
        tool = nil
        browser = deck.allPanes.compactMap { $0.content as? PreviewController }.last
        showsConversation = true
        layoutPanes()
    }

    private func toggleFiles() {
        guard presentedViewController == nil, filesNavigation == nil else { return }
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        let minimum = tool != nil && showsConversation && !focusesConversation ? 1320.0 : 1000.0
        if width >= minimum {
            showsFiles.toggle()
            layoutPanes()
        } else {
            remove(files)
            // UINavigationController owns the frame now, instead of our inline host constraints.
            files.view.translatesAutoresizingMaskIntoConstraints = true
            files.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            files.view.frame = CGRect(x: 0, y: 0, width: 360, height: 560)
            let navigation = BloomTheme.navigation(files)
            filesNavigation = navigation
            files.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Close", primaryAction: UIAction { [weak self] _ in self?.dismissFileSheetIfNeeded() })
            if traitCollection.horizontalSizeClass == .regular, let filesButton,
               navigationItem.rightBarButtonItems?.contains(where: { $0 === filesButton }) == true {
                navigation.modalPresentationStyle = .popover
                navigation.preferredContentSize = CGSize(width: 360, height: 560)
                navigation.popoverPresentationController?.barButtonItem = filesButton
            } else {
                navigation.modalPresentationStyle = .pageSheet
                navigation.sheetPresentationController?.detents = [.large()]
            }
            navigation.presentationController?.delegate = self
            present(navigation, animated: true)
        }
    }

    private func dismissFileSheetIfNeeded() {
        guard let navigation = filesNavigation, !isDismissingFiles else { return }
        isDismissingFiles = true
        navigation.dismiss(animated: true) { [weak self, weak navigation] in
            guard let navigation else { return }
            self?.restoreFiles(from: navigation)
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let navigation = filesNavigation,
              presentationController.presentedViewController === navigation else { return }
        restoreFiles(from: navigation)
    }

    private func restoreFiles(from navigation: UINavigationController) {
        guard filesNavigation === navigation else { return }
        // A second dismissal callback must never resolve the workspace's navigation controller
        // after Files has moved back into its inline host.
        filesNavigation = nil
        isDismissingFiles = false
        navigation.setViewControllers([], animated: false)
        files.navigationItem.rightBarButtonItem = nil
        install(files, in: filesHost)
        layoutPanes()
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        switch item.tag {
        case 0: focusConversation()
        case 1: openPreview()
        case 2: openReview(all: true)
        case 4:
            guard let pane = deck.allPanes.first(where: { $0.id == compactToolID }) else { return }
            focusesConversation = false
            deck.selectPane(pane); showDeck()
        default: toggleFiles()
        }
    }

    private func layoutPanes() {
        guard isViewLoaded else { return }
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        let compact = width < 900
        if usesCompactTabs != compact { usesCompactTabs = compact; updateToolbar() }
        compactTabs.isHidden = !compact
        compactTabsHeight?.constant = compact ? 49 + view.safeAreaInsets.bottom : 0
        let hasTool = tool != nil
        let splitConversation = hasTool && showsConversation && !focusesConversation && !compact && !primaryInDeck
        let inlineFiles = showsFiles && width >= (splitConversation ? 1320 : 1000) && files.parent === self
        conversationHost.isHidden = primaryInDeck || (hasTool && !splitConversation && !focusesConversation)
        conversationRule.isHidden = !splitConversation
        toolHost.isHidden = !hasTool || (focusesConversation && !primaryInDeck)
        reviewController.isReviewVisible = deck.selectedTab?.panes.contains { $0.content === reviewController } == true && !toolHost.isHidden
        filesHost.isHidden = !inlineFiles
        filesRule.isHidden = !inlineFiles
        filesWidth?.constant = 300
        conversationWidth?.isActive = splitConversation
        conversationWidth?.constant = min(600, max(400, (width - (inlineFiles ? 300 : 0)) * 0.46))
        if let wrapper = conversation as? WorkspacePaneController {
            wrapper.showsHeader = primaryInDeck || splitConversation
        }
        let actions = !primaryInDeck && !splitConversation && !conversationHost.isHidden
            ? chatContent(conversation)?.navigationItem.rightBarButtonItems ?? [] : []
        if conversationActions != actions {
            conversationActions = actions
            updateToolbar()
        }
        updateCompactSelection()
    }

    private func compactToolLabel(_ pane: WorkspaceToolPane) -> (title: String, symbol: String)? {
        if pane.content is WorkspaceNotesController { return ("Notes", PaneGlyph.notes) }
        if pane.content is WorkspaceTerminalController { return ("Terminal", PaneGlyph.terminal) }
        if pane.content is WorkspaceMediaController { return ("Media", "photo") }
        return nil
    }

    private func updateCompactSelection() {
        if let selected = deck.selectedPane, compactToolLabel(selected) != nil { compactToolID = selected.id }
        let extra = deck.allPanes.first { $0.id == compactToolID && compactToolLabel($0) != nil }
            ?? deck.allPanes.last { compactToolLabel($0) != nil }
        compactToolID = extra?.id
        var items = compactTabs.items?.filter { $0.tag != 4 } ?? []
        if let extra, let label = compactToolLabel(extra) {
            let item = compactTabs.items?.first { $0.tag == 4 }
                ?? UITabBarItem(title: label.title, image: UIImage(systemName: label.symbol), tag: 4)
            item.title = label.title; item.image = UIImage(systemName: label.symbol)
            item.accessibilityLabel = "Show " + label.title.lowercased()
            items.append(item)
        }
        if compactTabs.items?.map(\.tag) != items.map(\.tag) { compactTabs.setItems(items, animated: false) }
        let selected: Int
        if filesNavigation != nil { selected = 3 } else if tool == nil || focusesConversation { selected = 0 } else if deck.selectedPane?.id == extra?.id, extra != nil { selected = 4 } else {
            switch deck.selectedPane?.kind {
            case "chat": selected = 0
            case "browser": selected = 1
            case "review": selected = 2
            default: selected = 3
            }
        }
        compactTabs.selectedItem = compactTabs.items?.first { $0.tag == selected }
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

extension WorkspaceDeskController {
    private static let uiActions = ["pane_open", "pane_split", "pane_split_anchored", "pane_close", "pane_rename", "pane_list", "workspace_tabs", "workspace_tab_select",
                                    "browser_read", "browser_reload", "browser_go", "browser_scroll", "browser_text", "browser_screenshot",
                                    "terminal_start", "terminal_read", "terminal_write", "terminal_send_key", "media_show"]

    func openInitialMode(_ mode: WorkspaceStartMode) async {
        loadViewIfNeeded()
        do {
            switch mode {
            case .chat: break
            case .terminal: _ = try await openPane(kind: .terminal)
            case .browser: _ = try await openPane(kind: .browser, address: workspace.port > 0 ? "http://localhost:\(workspace.port)" : nil)
            }
        } catch { show(error) }
    }

    private func attachUI() {
        guard viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              connection.isActive, let service = review.service else { uiSession?.stop(); return }
        if uiSession == nil {
            uiSession = RemoteUIClientSession(workspaceID: workspace.id, actions: Self.uiActions) { [weak self] action in
                guard let self else { return .refusal("This workspace window has closed.") }
                return await handleUI(action)
            }
        }
        if uiSession?.error == nil { uiSession?.start(using: service) }
    }

    private func showAgentUIStatus() {
        let attached = uiSession?.isAttached == true
        let detail = attached
            ? "Agents in this workspace can use this device’s tabs, browsers and terminals while Bloom is active."
            : uiSession?.failureMessage ?? "Connect this workspace to let its agents use this device’s tabs, browsers and terminals."
        let alert = UIAlertController(title: "Agent UI tools", message: detail, preferredStyle: .alert)
        if !attached {
            alert.addAction(UIAlertAction(title: "Retry Agent UI", style: .default) { [weak self] _ in
                guard let self, connection.isActive, let service = review.service else { return }
                if let uiSession { uiSession.start(using: service) } else { attachUI() }
            })
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        if notification.name == UIScene.didActivateNotification { attachUI() } else { uiSession?.stop(); deck.suspendTerminals() }
    }

    private func focusConversation() {
        if primaryInDeck { deck.focusesSinglePane = true }
        if primaryInDeck, let pane = deck.allPanes.first(where: { $0.content === conversation }) {
            deck.selectPane(pane)
            showDeck()
        } else {
            compactTabs.selectedItem = compactTabs.items?.first
            focusesConversation = true
            layoutPanes()
        }
    }

    private func chatContent(_ controller: UIViewController?) -> ConversationController? {
        if let chat = controller as? ConversationController { return chat }
        return (controller as? WorkspacePaneController)?.embeddedContent as? ConversationController
    }

    private func requestNewPane(kind: PaneKind, split: SplitAxis? = nil) {
        Task { [weak self] in
            do { _ = try await self?.openPane(kind: kind, axis: split) } catch { self?.show(error) }
        }
    }

    private func openPane(kind: PaneKind, address: String? = nil, title: String? = nil,
                          focus: Bool = true, axis: SplitAxis? = nil, targetSessionID: SessionID? = nil) async throws -> WorkspaceToolPane {
        let targetPane = targetSessionID.flatMap { id in deck.allPanes.first { $0.sessionID == id } }
        if let targetSessionID, targetPane == nil, standalonePrimary?.id != targetSessionID {
            throw ConnectionFailure("The chat making this request is not open in a tab. Nothing was split.")
        }
        guard let service = review.service else { throw ConnectionFailure("Reconnect to this workspace's server first.") }
        let content: UIViewController
        var session: RemoteSession?
        switch kind {
        case .browser:
            if let address, !address.isEmpty { content = PreviewController(preview: try await preparePreview(address: address)) } else { content = PreviewController() }
        case .terminal:
            let name = "terminal-" + UUID().uuidString
            let model = connection, workspaceID = workspace.id
            content = WorkspaceTerminalController(name: name) { try await model.openTerminal(workspaceID: workspaceID, name: name) }
        case .chat:
            let context = try await service.workspaceContext(projectID: workspace.repoID)
            let controls = context.composer.controls
            let result = try await service.client.request(.call("workspace", ["workspaceID": .string(workspace.id.rawValue),
                "action": .object(["newSession": .object(["agent": .string(controls.agentKind.rawValue), "model": .string(controls.model),
                    "effort": .string(controls.effort), "permissionMode": .string(controls.permissionMode.rawValue)])])]))
            guard let value = result["created"]?["session"] else { throw ConnectionFailure("The server did not return the new conversation.") }
            let created = try JSONDecoder().decode(RemoteSession.self, from: JSONEncoder().encode(value))
            session = created
            content = ConversationController(model: connection, session: created)
            try await connection.refresh()
        }
        let name = title ?? session?.title ?? PaneNaming.nextTitle(base: kind.title, taken: deck.allPanes.filter { $0.kind == kind.rawValue }.map(\.title))
        let pane = WorkspaceToolPane(kind: kind.rawValue, title: name, content: content)
        pane.sessionID = session?.id
        configure(pane)
        let previousFocus = focusesConversation
        if let targetSessionID {
            if let targetPane, deck.allPanes.contains(where: { $0 === targetPane && $0.sessionID == targetSessionID }) {
                deck.selectPane(targetPane)
                focusesConversation = false
            } else if targetPane == nil, standalonePrimary?.id == targetSessionID {
                focusesConversation = true
            } else {
                deck.add(pane, focus: false)
                throw ConnectionFailure("The target chat changed before it could be split. The new content is available as a separate tab.")
            }
        }
        if axis != nil, targetPane == nil, !primaryInDeck, tool == nil || focusesConversation, let conversation, let primary = primarySession {
            remove(conversation)
            let root = WorkspaceToolPane(kind: "chat", title: primary.title, content: conversation)
            root.sessionID = primary.id
            primaryInDeck = true
            configure(root)
            deck.add(root)
        }
        deck.add(pane, focus: focus, split: axis)
        if focus { showDeck() } else { focusesConversation = previousFocus; layoutPanes() }
        if let terminal = content as? WorkspaceTerminalController { try await terminal.connect() }
        if let browser = content as? PreviewController { browser.loadViewIfNeeded(); self.browser = browser }
        if session != nil, title != nil { try await renamePane(pane, title: name) }
        return pane
    }

    private func configure(_ pane: WorkspaceToolPane) {
        if pane.kind == "source", let wrapper = pane.content as? WorkspacePaneController {
            wrapper.onClose = { [weak self, weak pane] in if let pane { self?.requestClosePane(pane) } }
        }
        if let review = pane.content as? WorkspaceReviewController {
            review.onClose = { [weak self, weak pane] in if let pane { self?.requestClosePane(pane) } }
        }
        if let browser = pane.content as? PreviewController {
            browser.onClose = { [weak self, weak pane] in if let pane { self?.requestClosePane(pane) } }
            browser.onNavigate = { [weak self, weak pane] address in
                guard let self, let pane else { throw CancellationError() }
                try await self.navigate(pane, address: address)
            }
        }
        if let terminal = pane.content as? WorkspaceTerminalController {
            terminal.onClose = { [weak self, weak pane] in if let pane { self?.requestClosePane(pane) } }
            terminal.onOpenURL = { [weak self] url in
                Task { do { _ = try await self?.openPane(kind: .browser, address: url.absoluteString) } catch { self?.show(error) } }
            }
        }
        if let chat = (pane.content as? ConversationController) ?? ((pane.content as? WorkspacePaneController)?.embeddedContent as? ConversationController) {
            chat.onOpenSession = { [weak self, weak pane] session in
                guard let self, let pane else { return }
                if pane.content === conversation { replaceConversation(with: session); return }
                let chat = ConversationController(model: connection, session: session)
                deck.replace(pane, content: chat)
                pane.sessionID = session.id
                deck.rename(pane, title: session.title)
                configure(pane)
            }
        }
    }

    private func navigate(_ pane: WorkspaceToolPane, address: String) async throws {
        let requestID = UUID()
        previewNavigationRequests[pane.id] = requestID
        defer {
            if previewNavigationRequests[pane.id] == requestID { previewNavigationRequests[pane.id] = nil }
        }
        let lease = try await preparePreview(address: address)
        guard !Task.isCancelled, previewNavigationRequests[pane.id] == requestID,
              deck.allPanes.contains(where: { $0 === pane }) else { lease.close(); throw CancellationError() }
        let preview = PreviewController(preview: lease)
        deck.replace(pane, content: preview)
        configure(pane)
        preview.loadViewIfNeeded()
        browser = preview
    }

    private func requestRename(_ pane: WorkspaceToolPane) {
        let alert = UIAlertController(title: "Rename pane", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = pane.title }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self else { return }
            Task { do { try await self.renamePane(pane, title: alert.textFields?.first?.text ?? "") } catch { self.show(error) } }
        })
        present(alert, animated: true)
    }

    private func renamePane(_ pane: WorkspaceToolPane, title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1_024 else { throw ConnectionFailure("Enter a pane name between 1 and 1,024 bytes.") }
        if let id = pane.sessionID {
            guard let service = review.service else { throw ConnectionFailure("Reconnect before renaming this conversation.") }
            _ = try await service.client.request(.call("renameSession", ["sessionID": .string(id.rawValue), "title": .string(title)]))
        }
        deck.rename(pane, title: title)
        (pane.content as? WorkspacePaneController)?.rename(title)
    }

    private func requestClosePane(_ pane: WorkspaceToolPane) {
        Task { [weak self] in do { try await self?.closePane(pane) } catch { self?.show(error) } }
    }

    private func closePane(_ pane: WorkspaceToolPane) async throws {
        if let id = pane.sessionID {
            guard let service = review.service else { throw ConnectionFailure("Reconnect before closing this conversation.") }
            _ = try await service.client.request(.call("closeSession", ["sessionID": .string(id.rawValue)]))
            try await connection.refresh()
        }
        let wasPrimary = pane.content === conversation
        deck.close(pane)
        if wasPrimary { conversation = nil; preferredSessionID = nil; primaryInDeck = false; openConversation(); layoutPanes() }
    }

    private var standalonePrimary: RemoteSession? { primaryInDeck ? nil : primarySession }

    private func openNotes() {
        if let notes { setTool(notes); return }
        let notes = WorkspaceNotesController(model: connection, workspaceID: workspace.id)
        self.notes = notes
        setTool(notes)
    }

    private var primarySession: RemoteSession? {
        let sessions = connection.catalogue?.sessions.filter { $0.workspaceID == workspace.id } ?? []
        return sessions.first { $0.id == preferredSessionID } ?? sessions.first
    }

    private func selectedPane(kind: String?) throws -> WorkspaceToolPane {
        guard let tab = deck.selectedTab, tool != nil, !focusesConversation || primaryInDeck else { throw ConnectionFailure("Select the pane you want to change first.") }
        if let pane = deck.selectedPane, kind == nil || pane.kind == kind { return pane }
        let matches = tab.panes.filter { $0.kind == kind }
        guard matches.count == 1, let pane = matches.first else { throw ConnectionFailure("Select a tab with exactly one matching pane first.") }
        return pane
    }

    private func numberedPane(kind: String, number: Int?) throws -> WorkspaceToolPane {
        let panes = deck.allPanes.filter { $0.kind == kind }
        if let number, number > 0, number <= panes.count { return panes[number - 1] }
        if number == nil, panes.count == 1 { return panes[0] }
        throw ConnectionFailure("Call pane_list and choose a current \(kind) number.")
    }

    private func relativePath(_ path: String) throws -> String {
        let relative: String
        if path.hasPrefix("/"), let root = workspace.path, path.hasPrefix(root + "/") { relative = String(path.dropFirst(root.count + 1)) } else { relative = path }
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator: "/").contains("..") else {
            throw ConnectionFailure("Choose a file inside this workspace.")
        }
        return relative
    }

    private func browserReport(_ pane: WorkspaceToolPane) -> BrowserPaneReport {
        let page = pane.content as? PreviewController
        let number = (deck.allPanes.filter { $0.kind == "browser" }.firstIndex { $0 === pane } ?? 0) + 1
        return BrowserPaneReport(number: number, name: pane.title, address: page?.currentAddress ?? "", pageTitle: page?.loadedPageTitle ?? "",
            isLoading: page?.pageIsLoading ?? false, canGoBack: page?.pageCanGoBack ?? false, canGoForward: page?.pageCanGoForward ?? false,
            isLive: page?.isViewLoaded == true, failure: page?.lastPageFailure.map { BrowserLoadFailure(title: "Preview couldn’t load", message: $0) })
    }

    private func panesJSON() -> JSONValue {
        var entries: [PaneCensusEntry] = []
        if let session = standalonePrimary { entries.append(.init(kind: .chat, name: session.title, isShowing: !conversationHost.isHidden)) }
        var terminal = 0
        for pane in deck.allPanes {
            let showing = tool != nil && !toolHost.isHidden && deck.showingPaneIDs.contains(pane.id)
            var entry = PaneCensusEntry(kind: PaneCensusKind(rawValue: pane.kind) ?? .review, name: pane.title, isShowing: showing)
            if pane.kind == "browser" { entry.browser = browserReport(pane) }
            if let view = pane.content as? WorkspaceTerminalController {
                terminal += 1
                entry.terminal = TerminalPaneReport(number: terminal, name: pane.title, isLive: view.isConnected)
            }
            entries.append(entry)
        }
        return PaneCensus(entries: entries).json
    }

    private func tabDetail(_ pane: WorkspaceToolPane) -> WorkspaceTabDetail {
        switch pane.kind {
        case "browser": return .browser(browserReport(pane))
        case "terminal": return .terminal(.init(directory: workspace.path ?? "", isLive: (pane.content as? WorkspaceTerminalController)?.isConnected == true))
        case "chat":
            let session = connection.catalogue?.sessions.first { $0.id == pane.sessionID }
            return .chat(.init(agent: AgentKind(rawValue: session?.agentKind ?? "") ?? .claudeCode, state: SessionState(rawValue: session?.state ?? "") ?? .idle, messages: chatContent(pane.content)?.transcriptMessageCount ?? 0))
        case "notes": return .notes(.init(characters: notes?.characters ?? 0))
        // The existing protocol groups source and diff viewers under its file-review detail.
        // Native tabs retain their distinction and filename without changing that wire contract.
        case "source", "review": return .review(.init(file: pane.path ?? ""))
        default: return .review(.init(file: pane.path ?? ""))
        }
    }

    private func tabsJSON() -> JSONValue {
        var reports: [WorkspaceTabReport] = []
        if let session = standalonePrimary {
            reports.append(.init(number: 1, title: session.title, isActive: focusesConversation || tool == nil,
                detail: .chat(.init(agent: AgentKind(rawValue: session.agentKind) ?? .claudeCode, state: SessionState(rawValue: session.state) ?? .idle, messages: chatContent(conversation)?.transcriptMessageCount ?? 0))))
        }
        for tab in deck.tabs {
            guard let first = tab.panes.first else { continue }
            let panes = tab.panes.count > 1 ? tab.panes.map { pane in
                WorkspaceTabPane(kind: PaneCensusKind(rawValue: pane.kind) ?? .review, title: pane.title, browser: pane.kind == "browser" ? browserReport(pane).number : nil)
            } : []
            reports.append(.init(number: reports.count + 1, title: tab.title, isActive: tab.id == deck.selectedID && (!focusesConversation || primaryInDeck) && tool != nil,
                                 detail: tabDetail(first), panes: panes))
        }
        return WorkspaceTabCensus(tabs: reports).json
    }

    private func handleUI(_ action: RemoteUIAction) async -> RemoteUIResult {
        guard connection.isActive, viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              review.service != nil else { return .refusal("This workspace UI is not active on this device.") }
        let args = action.arguments
        do {
            switch action.name {
            case "pane_list": return .init(value: panesJSON())
            case "workspace_tabs": return .init(value: tabsJSON())
            case "pane_open", "pane_split", "pane_split_anchored":
                guard let raw = args["kind"]?.stringValue, let kind = PaneKind(rawValue: raw) else { throw ConnectionFailure("Choose chat, browser or terminal.") }
                if action.name == "pane_split_anchored", args["target"]?.stringValue == "this_chat", args["sessionID"]?.stringValue == nil {
                    throw ConnectionFailure("The server did not identify the chat to split beside. Nothing was split.")
                }
                let axis: SplitAxis? = action.name != "pane_open" ? (args["direction"]?.stringValue == "below" ? .vertical : .horizontal) : nil
                let pane = try await openPane(kind: kind, address: args["url"]?.stringValue, title: args["title"]?.stringValue, focus: args["focus"]?.boolValue ?? true, axis: axis,
                    targetSessionID: action.name == "pane_split_anchored" && args["target"]?.stringValue == "this_chat"
                        ? args["sessionID"]?.stringValue.map(SessionID.init) : nil)
                return .init(text: "Opened \(pane.title).")
            case "pane_close":
                if let primary = standalonePrimary, tool == nil || focusesConversation, args["kind"]?.stringValue == nil || args["kind"]?.stringValue == "chat" {
                    guard let service = review.service else { throw ConnectionFailure("Reconnect before closing this conversation.") }
                    _ = try await service.client.request(.call("closeSession", ["sessionID": .string(primary.id.rawValue)]))
                    try await connection.refresh()
                    if let conversation { remove(conversation) }
                    conversation = nil; preferredSessionID = nil; openConversation()
                    return .init(text: "Closed \(primary.title).")
                }
                let pane = try selectedPane(kind: args["kind"]?.stringValue)
                guard ["chat", "browser", "terminal"].contains(pane.kind) else { throw ConnectionFailure("This tool closes chat, browser and terminal panes only.") }
                try await closePane(pane)
                return .init(text: "Closed \(pane.title).")
            case "pane_rename":
                if let primary = standalonePrimary, tool == nil || focusesConversation, args["kind"]?.stringValue == nil || args["kind"]?.stringValue == "chat" {
                    guard let service = review.service else { throw ConnectionFailure("Reconnect before renaming this conversation.") }
                    let title = args["title"]?.stringValue ?? ""
                    _ = try await service.client.request(.call("renameSession", ["sessionID": .string(primary.id.rawValue), "title": .string(title)]))
                    (conversation as? WorkspacePaneController)?.rename(title)
                    try await connection.refresh()
                    return .init(text: "Renamed the conversation to \(title).")
                }
                let pane = try selectedPane(kind: args["kind"]?.stringValue)
                try await renamePane(pane, title: args["title"]?.stringValue ?? "")
                return .init(text: "Renamed the pane to \(pane.title).")
            case "workspace_tab_select":
                let reports = tabsJSON()["tabs"]?.arrayValue ?? []
                let target: Int
                if let number = args["tab"]?.intValue { target = number } else {
                    let matches = reports.filter { $0["title"]?.stringValue == args["title"]?.stringValue }
                    guard matches.count == 1, let number = matches.first?["tab"]?.intValue else { throw ConnectionFailure("That title does not identify exactly one tab. Call workspace_tabs.") }
                    target = number
                }
                if standalonePrimary != nil && target == 1 { focusesConversation = true; layoutPanes() } else {
                    let index = target - (standalonePrimary == nil ? 1 : 2)
                    guard deck.tabs.indices.contains(index) else { throw ConnectionFailure("That tab number is no longer present. Call workspace_tabs.") }
                    deck.select(deck.tabs[index].id); showDeck()
                }
                return .init(text: "Selected tab \(target).")
            case "browser_read", "browser_reload", "browser_go", "browser_scroll", "browser_text", "browser_screenshot":
                let pane = try numberedPane(kind: "browser", number: args["browser"]?.intValue)
                guard let page = pane.content as? PreviewController else { throw ConnectionFailure("The browser is unavailable.") }
                switch action.name {
                case "browser_read": return .init(value: browserReport(pane).json)
                case "browser_reload": page.reloadPage(); return .init(text: "Reloading \(pane.title).")
                case "browser_go": try await navigate(pane, address: args["url"]?.stringValue ?? ""); return .init(text: "Navigating \(pane.title).")
                case "browser_text": return .init(text: BridgeUntrustedText.wrap(try await page.pageText(), from: page.currentAddress))
                case "browser_screenshot": return .init(text: "Screenshot of \(pane.title).", png: try await page.pageSnapshot())
                default:
                    let movement = try BrowserScroll.parse(direction: args["direction"]?.stringValue, pages: args["pages"]).get()
                    return .init(text: try await page.scrollPage(movement))
                }
            case "terminal_start":
                let pane = try await openPane(kind: .terminal, title: args["title"]?.stringValue, focus: args["focus"]?.boolValue ?? true)
                guard let terminal = pane.content as? WorkspaceTerminalController else { throw ConnectionFailure("The terminal is unavailable.") }
                try await terminal.send(Data(((args["command"]?.stringValue ?? "") + "\r").utf8))
                return .init(text: "Started the command in \(pane.title).")
            case "terminal_read", "terminal_write", "terminal_send_key":
                let pane = try numberedPane(kind: "terminal", number: args["terminal"]?.intValue)
                guard let terminal = pane.content as? WorkspaceTerminalController else { throw ConnectionFailure("The terminal is unavailable.") }
                try await terminal.connect()
                if action.name == "terminal_read" {
                    let number = (deck.allPanes.filter { $0.kind == "terminal" }.firstIndex { $0 === pane } ?? 0) + 1
                    return .init(value: .object(["text": .string(terminal.readText(maxLines: args["lines"]?.intValue ?? 500)), "terminal": .integer(number), "name": .string(pane.title), "live": .bool(terminal.isConnected)]))
                }
                if action.name == "terminal_write" {
                    try await terminal.send(Data(((args["text"]?.stringValue ?? "") + ((args["submit"]?.boolValue ?? true) ? "\r" : "")).utf8))
                } else {
                    guard let key = TerminalKey(rawValue: args["key"]?.stringValue ?? "") else { throw ConnectionFailure("Choose a supported terminal key.") }
                    try await terminal.sendKey(key)
                }
                return .init(text: "Sent input to \(pane.title).")
            case "media_show":
                let path = try relativePath(args["path"]?.stringValue ?? "")
                let content = WorkspaceMediaController(model: connection, workspaceID: workspace.id, path: path)
                let pane = WorkspaceToolPane(kind: "review", title: args["caption"]?.stringValue ?? (path as NSString).lastPathComponent, content: content)
                pane.path = path
                deck.add(pane); showDeck()
                try await content.prepare()
                return .init(text: "Opened \(path) in the workspace.")
            default: return .refusal("This device does not implement that workspace UI action.")
            }
        } catch let refusal as PaneRefusal { return .refusal(refusal.sentence) } catch { return .refusal(error.localizedDescription) }
    }

    #if DEBUG
    var liveUIAttached: Bool { uiSession?.isAttached == true }
    var liveUIFailure: String? { uiSession?.error }
    func livePaneCensus() -> JSONValue { panesJSON() }
    func performLiveUIAction(_ action: RemoteUIAction) async -> RemoteUIResult { await handleUI(action) }

    /// Opt-in real SSH/HTTPS terminal check. The temporary shell belongs only to this test.
    func verifyLiveTerminal() async throws -> [String: String] {
        let pane = try await openPane(kind: .terminal, title: "Terminal verification")
        guard let terminal = pane.content as? WorkspaceTerminalController else { throw ConnectionFailure("The native terminal did not open.") }
        do {
            let marker = "bloom_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try await terminal.send(Data("BLOOM_NATIVE_CHECK=\(marker); printf '\\n%s\\n' \"$BLOOM_NATIVE_CHECK\"\r".utf8))
            try await waitForTerminal(terminal, line: marker)
            try await terminal.resize(columns: 101, rows: 31)
            try await Task.sleep(for: .milliseconds(150))
            try await terminal.send(Data("stty size\r".utf8))
            try await waitForTerminal(terminal, line: "31 101")
            try await terminal.send(Data("sleep 30\r".utf8))
            try await Task.sleep(for: .milliseconds(250))
            try await terminal.sendKey(.controlC)
            try await terminal.send(Data("printf '\\n%s_interrupted\\n' \"$BLOOM_NATIVE_CHECK\"\r".utf8))
            try await waitForTerminal(terminal, line: marker + "_interrupted")
            terminal.disconnect()
            try await terminal.connect()
            try await terminal.send(Data("printf '\\n%s_reconnected\\n' \"$BLOOM_NATIVE_CHECK\"\r".utf8))
            try await waitForTerminal(terminal, line: marker + "_reconnected")
            let result = ["terminalName": terminal.terminalName, "transport": "native", "checks": "output, input, resize, control-c, detach, reconnect, shell state preserved", "output": terminal.readText(maxLines: 40)]
            if let window = view.window {
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-live-terminal.png"))
            }
            try await connection.closeTerminal(workspaceID: workspace.id, name: terminal.terminalName)
            deck.close(pane)
            return result
        } catch {
            let details = ["error": error.localizedDescription, "output": terminal.readText(maxLines: 80)]
            try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL.documentsDirectory.appendingPathComponent("bloom-live-terminal-failure.json"), options: .atomic)
            try? await connection.closeTerminal(workspaceID: workspace.id, name: terminal.terminalName)
            deck.close(pane)
            throw error
        }
    }

    private func waitForTerminal(_ terminal: WorkspaceTerminalController, line: String) async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if terminal.readText(maxLines: 200).split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == line }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ConnectionFailure("The native terminal did not receive its expected output: \(line)")
    }

    #endif
}
