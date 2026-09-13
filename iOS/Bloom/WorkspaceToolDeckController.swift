import UIKit
import BloomClient

@MainActor
final class WorkspaceToolPane {
    let id = UUID().uuidString
    let kind: String
    var title: String
    var content: UIViewController
    var sessionID: SessionID?
    var path: String?
    init(kind: String, title: String, content: UIViewController) {
        self.kind = kind; self.title = title; self.content = content
    }
    func close() {
        (content as? PreviewController)?.closePreview()
        (content as? WorkspaceTerminalController)?.disconnect()
    }
}

@MainActor
final class WorkspaceToolTab {
    let id = UUID()
    var layout: SplitLayout
    var contents: [String: WorkspaceToolPane]
    init(_ pane: WorkspaceToolPane) { layout = SplitLayout(pane: pane.id); contents = [pane.id: pane] }
    var panes: [WorkspaceToolPane] { layout.panes.compactMap { contents[$0] } }
    var title: String { panes.first?.title ?? "Tab" }
}

/// Native tab selection and containment around the same split tree/geometry that Mac uses.
final class WorkspaceToolDeckController: UIViewController, UIGestureRecognizerDelegate {
    private(set) var tabs: [WorkspaceToolTab] = []
    private(set) var selectedID: UUID?
    var onEmpty: (() -> Void)?
    var onSelection: (() -> Void)?
    var onNewPane: ((PaneKind, SplitAxis?) -> Void)?
    var onRename: ((WorkspaceToolPane) -> Void)?
    var onClosePane: ((WorkspaceToolPane) -> Void)?
    var onCloseTab: ((WorkspaceToolTab) -> Void)?
    var onEndTerminal: ((WorkspaceToolPane) -> Void)?
    var alwaysShowsTabBar = false {
        didSet {
            if alwaysShowsTabBar != oldValue, isViewLoaded { updateTabHeader(); renderSelection(); onSelection?() }
        }
    }
    /// Temporarily present the focused leaf without changing the saved split or selected tab.
    var focusesSinglePane = false {
        didSet {
            guard focusesSinglePane != oldValue, isViewLoaded else { return }
            renderSelection()
            view.setNeedsLayout()
        }
    }
    private let tabRow = UIStackView()
    private var tabViews: [UUID: UIView] = [:]
    private let leafSelector = UISegmentedControl()
    private let tabScroll = UIScrollView()
    private let canvas = WorkspacePaneCanvas()
    private let emptyState = UIContentUnavailableView(configuration: .empty())
    private let menu = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let splitButton = UIButton(type: .system)
    private let tabHeader = UIStackView()
    private var tabHeaderHeight: NSLayoutConstraint?
    private var shouldRevealSelectedTab = false
    private var previousTabWidth: CGFloat = 0
    private var leafHeight: NSLayoutConstraint?
    private struct DividerID: Hashable {
        let tab: UUID
        let path: [Int]
        let axis: SplitAxis
        let panes: [String]
    }
    private var dividers: [DividerID: WorkspaceSplitDividerView] = [:]
    private var installed: [String: WorkspaceToolPane] = [:]
    private var focusGestures: [String: UITapGestureRecognizer] = [:]
    private var compactSplit = false
    private var showsFocusedPaneOnly: Bool { compactSplit || focusesSinglePane }
    var selectedTab: WorkspaceToolTab? { tabs.first { $0.id == selectedID } }
    var selectedPane: WorkspaceToolPane? { selectedTab.flatMap { $0.contents[$0.layout.focus] } }
    var allPanes: [WorkspaceToolPane] { tabs.flatMap(\.panes) }
    var showingPaneIDs: Set<String> { Set(installed.keys) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        canvas.onLayout = { [weak self] in self?.layoutCanvas() }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "square.stack.3d.up")
        empty.imageProperties.tintColor = BloomTheme.accent
        empty.text = "Open a tab to start working"
        empty.secondaryText = "Choose + for a conversation, browser or terminal."
        emptyState.configuration = empty
        canvas.addSubview(emptyState)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: WorkspaceToolDeckController, _: UITraitCollection) in
            controller.refreshTabs()
        }
        leafSelector.addAction(UIAction { [weak self] _ in
            guard let self, let tab = selectedTab, tab.panes.indices.contains(leafSelector.selectedSegmentIndex) else { return }
            tab.layout.setFocus(tab.panes[leafSelector.selectedSegmentIndex].id)
            renderSelection()
            updateMenu()
            onSelection?()
        }, for: .valueChanged)
        leafSelector.accessibilityLabel = "Split panes"
        tabScroll.showsHorizontalScrollIndicator = false
        tabScroll.accessibilityIdentifier = "workspace-tabs"
        tabRow.spacing = 4
        tabScroll.addSubview(tabRow)
        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.showsMenuAsPrimaryAction = true
        addButton.accessibilityLabel = "New tab"
        addButton.accessibilityIdentifier = "workspace-new-tab"
        splitButton.setImage(UIImage(systemName: "rectangle.split.2x1"), for: .normal)
        splitButton.showsMenuAsPrimaryAction = true
        splitButton.accessibilityLabel = "Split selected pane"
        splitButton.accessibilityIdentifier = "workspace-split-pane"
        menu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menu.showsMenuAsPrimaryAction = true
        menu.accessibilityLabel = "Tab and split options"
        [tabScroll, addButton, splitButton, menu].forEach { tabHeader.addArrangedSubview($0) }
        tabHeader.spacing = 2
        tabHeader.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tabHeader.isLayoutMarginsRelativeArrangement = true
        let stack = UIStackView(arrangedSubviews: [tabHeader, leafSelector, canvas])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        leafHeight = leafSelector.heightAnchor.constraint(equalToConstant: 0)
        leafHeight?.isActive = true
        tabHeaderHeight = tabHeader.heightAnchor.constraint(equalToConstant: 0)
        tabHeaderHeight?.isActive = true
        let menuWidth = menu.widthAnchor.constraint(equalToConstant: 44)
        menuWidth.priority = .defaultHigh
        menuWidth.isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 44),
            splitButton.widthAnchor.constraint(equalToConstant: 44)
        ])
        refreshTabs()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = tabHeaderHeight?.constant ?? 44
        let width = tabRow.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        tabRow.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tabScroll.contentSize = tabRow.bounds.size
        tabRow.layoutIfNeeded()
        revealSelectedTab()
    }

    private func layoutCanvas() {
        let compact = canvas.bounds.width < 440
        if compact != compactSplit { compactSplit = compact; renderSelection() }
        layoutSelectedPanes()
    }

    func add(_ pane: WorkspaceToolPane, focus: Bool = true, split: SplitAxis? = nil) {
        loadViewIfNeeded()
        if let split, let tab = selectedTab {
            tab.contents[pane.id] = pane
            let oldFocus = tab.layout.focus
            tab.layout.split(oldFocus, axis: split, into: pane.id)
            if !focus { tab.layout.setFocus(oldFocus) }
        } else {
            let tab = WorkspaceToolTab(pane)
            tabs.append(tab)
            if focus || selectedID == nil { selectedID = tab.id }
        }
        refreshTabs()
    }

    func select(_ id: UUID, pane: String? = nil) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        if let pane { tab.layout.setFocus(pane) }
        refreshTabs()
    }

    func selectPane(_ pane: WorkspaceToolPane) {
        guard let tab = tabs.first(where: { $0.contents[pane.id] != nil }) else { return }
        select(tab.id, pane: pane.id)
    }

    func rename(_ pane: WorkspaceToolPane, title: String) {
        pane.title = title
        refreshTabs()
    }

    func replace(_ pane: WorkspaceToolPane, content: UIViewController) {
        detach(pane.content)
        pane.close()
        pane.content = content
        installed[pane.id] = nil
        refreshTabs()
    }

    func close(_ pane: WorkspaceToolPane) {
        guard let index = tabs.firstIndex(where: { $0.contents[pane.id] != nil }) else { return }
        let tab = tabs[index]
        pane.close()
        detach(pane.content)
        installed[pane.id] = nil
        if tab.layout.close(pane.id) { tab.contents[pane.id] = nil } else {
            tabs.remove(at: index)
            if selectedID == tab.id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        }
        refreshTabs()
        if tabs.isEmpty { onEmpty?() }
    }

    func closeAll() {
        for pane in allPanes { pane.close(); detach(pane.content) }
        tabs.removeAll(); installed.removeAll(); selectedID = nil
        refreshTabs()
    }

    func suspendTerminals() { for pane in allPanes { (pane.content as? WorkspaceTerminalController)?.disconnect() } }

    private func refreshTabs() {
        guard isViewLoaded else { return }
        for view in tabRow.arrangedSubviews { tabRow.removeArrangedSubview(view); view.removeFromSuperview() }
        tabViews.removeAll()
        for tab in tabs {
            let item = tabView(tab)
            tabViews[tab.id] = item
            tabRow.addArrangedSubview(item)
        }
        updateTabHeader()
        shouldRevealSelectedTab = true
        view.setNeedsLayout()
        updateMenu()
        renderSelection()
        onSelection?()
    }

    private func renderSelection() {
        guard isViewLoaded else { return }
        let tab = selectedTab
        let visible = showsFocusedPaneOnly ? tab?.panes.filter { $0.id == tab?.layout.focus } ?? [] : tab?.panes ?? []
        for pane in visible where pane.kind == "chat" {
            (pane.content as? WorkspacePaneController)?.showsHeader = !alwaysShowsTabBar || (tab?.panes.count ?? 0) > 1
        }
        let ids = Set(visible.map(\.id))
        for (id, pane) in installed where !ids.contains(id) { detach(pane.content); installed[id] = nil }
        for pane in visible where installed[pane.id] == nil {
            let visible = view.window != nil
            if visible { pane.content.beginAppearanceTransition(true, animated: false) }
            addChild(pane.content)
            pane.content.view.translatesAutoresizingMaskIntoConstraints = true
            pane.content.view.autoresizingMask = []
            canvas.addSubview(pane.content.view)
            let tap = UITapGestureRecognizer(target: self, action: #selector(focusPane(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            pane.content.view.addGestureRecognizer(tap)
            focusGestures[pane.id] = tap
            pane.content.didMove(toParent: self)
            if visible { pane.content.endAppearanceTransition() }
            installed[pane.id] = pane
        }
        leafSelector.removeAllSegments()
        if showsFocusedPaneOnly, let tab, tab.panes.count > 1 {
            for (index, pane) in tab.panes.enumerated() { leafSelector.insertSegment(withTitle: pane.title, at: index, animated: false) }
            leafSelector.selectedSegmentIndex = tab.panes.firstIndex { $0.id == tab.layout.focus } ?? 0
            leafHeight?.constant = 44
            leafSelector.isHidden = false
        } else { leafHeight?.constant = 0; leafSelector.isHidden = true }
        layoutSelectedPanes()
    }

    private func layoutSelectedPanes() {
        emptyState.frame = canvas.bounds
        emptyState.isHidden = selectedTab != nil
        guard let tab = selectedTab else { clearDividers(); return }
        if showsFocusedPaneOnly {
            clearDividers()
            installed[tab.layout.focus]?.content.view.frame = canvas.bounds
            return
        }
        let geometry = tab.layout.geometry(in: canvas.bounds.size, dividerThickness: 1)
        for pane in geometry.panes { installed[pane.pane]?.content.view.frame = pane.frame }
        let paneIDs = tab.layout.panes
        let keys = Set(geometry.dividers.map { DividerID(tab: tab.id, path: $0.path, axis: $0.axis, panes: paneIDs) })
        for (key, divider) in dividers where !keys.contains(key) {
            divider.removeFromSuperview()
            dividers[key] = nil
        }
        for divider in geometry.dividers {
            let key = DividerID(tab: tab.id, path: divider.path, axis: divider.axis, panes: paneIDs)
            if let view = dividers[key] { view.update(divider); canvas.bringSubviewToFront(view) } else {
                let view = WorkspaceSplitDividerView(geometry: divider)
                view.onResize = { [weak self, weak tab] ratio in
                    guard let self, let tab, selectedTab === tab, tab.layout.panes == key.panes else { return }
                    guard tab.layout.setRatio(ratio, at: key.path) else { return }
                    layoutSelectedPanes()
                }
                canvas.addSubview(view)
                dividers[key] = view
            }
        }
    }

    private func clearDividers() {
        for divider in dividers.values { divider.removeFromSuperview() }
        dividers.removeAll()
    }

    private func revealSelectedTab() {
        let resized = previousTabWidth != tabScroll.bounds.width
        previousTabWidth = tabScroll.bounds.width
        guard shouldRevealSelectedTab || resized, tabScroll.bounds.width > 0 else { return }
        shouldRevealSelectedTab = false
        guard let selectedID, let item = tabViews[selectedID] else { return }
        tabScroll.scrollRectToVisible(item.convert(item.bounds, to: tabScroll), animated: false)
    }

    private func updateTabHeader() {
        let shows = alwaysShowsTabBar || tabs.count > 1
        tabHeaderHeight?.constant = shows ? max(44, ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight) + 16) : 0
        tabHeader.isHidden = !shows
        // The primary controls remain visible; secondary actions are in the selected tab's menu.
        menu.isHidden = alwaysShowsTabBar
        view.setNeedsLayout()
    }

    private func tabView(_ tab: WorkspaceToolTab) -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = tab.title
        configuration.image = UIImage(systemName: tab.panes.count > 1 ? "rectangle.split.2x1" : tabSymbol(tab.panes.first?.kind))
        configuration.imagePadding = 7
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 4)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        button.configuration = configuration
        button.accessibilityLabel = tab.title
        button.accessibilityValue = tab.panes.count > 1 ? "\(tab.panes.count) panes" : tab.panes.first?.kind
        if tab.id == selectedID { button.accessibilityTraits.insert(.selected) }
        button.addAction(UIAction { [weak self] _ in self?.select(tab.id) }, for: .touchUpInside)
        button.menu = tabMenu(tab)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1)), for: .normal)
        close.accessibilityLabel = "Close \(tab.title) tab"
        close.addAction(UIAction { [weak self] _ in self?.onCloseTab?(tab) }, for: .touchUpInside)
        close.isEnabled = onCloseTab != nil
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let item = UIStackView(arrangedSubviews: [button, close])
        item.layer.cornerRadius = 10
        item.layer.cornerCurve = .continuous
        item.backgroundColor = tab.id == selectedID ? BloomTheme.accent.withAlphaComponent(0.1) : .clear
        let labelWidth = (tab.title as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline)]).width
        item.widthAnchor.constraint(equalToConstant: min(280, max(160, ceil(labelWidth) + 90))).isActive = true
        return item
    }

    private func tabSymbol(_ kind: String?) -> String {
        switch kind {
        case "chat": "bubble.left.and.bubble.right"
        case "terminal": "terminal"
        case "browser": "safari"
        case "source": "doc.text"
        case "notes": "note.text"
        default: "doc.text.magnifyingglass"
        }
    }

    private func tabMenu(_ tab: WorkspaceToolTab) -> UIMenu {
        var actions: [UIMenuElement] = []
        if tab.contents[tab.layout.focus] != nil {
            actions.append(UIAction(title: "Rename Pane", image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let pane = tab.contents[tab.layout.focus] else { return }
                self?.onRename?(pane)
            })
            if tab.panes.count > 1 {
                actions.append(UIAction(title: "Close Selected Pane", image: UIImage(systemName: "rectangle.badge.xmark")) { [weak self] _ in
                    guard let pane = tab.contents[tab.layout.focus] else { return }
                    self?.onClosePane?(pane)
                })
            }
        }
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        for (title, delta) in [("Move Tab Left", -1), ("Move Tab Right", 1)] {
            actions.append(UIAction(title: title, attributes: tabs.indices.contains(index + delta) ? [] : [.disabled]) { [weak self] _ in
                guard let self, let current = tabs.firstIndex(where: { $0.id == tab.id }), tabs.indices.contains(current + delta) else { return }
                tabs.swapAt(current, current + delta)
                refreshTabs()
            })
        }
        actions.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: onCloseTab == nil ? [.disabled] : []) { [weak self] _ in self?.onCloseTab?(tab) })
        return UIMenu(children: actions)
    }

    @objc private func focusPane(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let tab = selectedTab,
              let pane = tab.panes.first(where: { $0.content.viewIfLoaded === gesture.view }), tab.layout.focus != pane.id else { return }
        tab.layout.setFocus(pane.id)
        updateMenu()
        onSelection?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// Shared with the workspace toolbar, including when the single-tab header is hidden.
    var paneActionsMenu: UIMenu {
        var groups: [UIMenuElement] = []
        groups.append(UIMenu(title: "New tab", children: PaneKind.allCases.map { kind in
            UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in self?.onNewPane?(kind, nil) }
        }))
        for (title, axis) in [("Split beside", SplitAxis.horizontal), ("Split below", SplitAxis.vertical)] {
            groups.append(UIMenu(title: title, children: PaneKind.allCases.map { kind in
                UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in self?.onNewPane?(kind, axis) }
            }))
        }
        if let pane = selectedPane {
            if pane.kind == "terminal" {
                groups.append(UIAction(title: "End terminal session", image: UIImage(systemName: "stop.circle"), attributes: .destructive) { [weak self] _ in self?.onEndTerminal?(pane) })
            }
            groups += [UIAction(title: "Rename pane", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRename?(pane) },
                       UIAction(title: "Close pane", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.onClosePane?(pane) }]
        }
        return UIMenu(children: groups)
    }

    private func updateMenu() {
        menu.menu = paneActionsMenu
        addButton.menu = UIMenu(title: "New Tab", children: PaneKind.allCases.map { kind in
            UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in self?.onNewPane?(kind, nil) }
        })
        splitButton.isEnabled = selectedPane != nil
        splitButton.menu = UIMenu(title: "Split Selected Pane", children: [("Beside", SplitAxis.horizontal), ("Below", SplitAxis.vertical)].map { title, axis in
            UIMenu(title: title, image: UIImage(systemName: axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2"), children: PaneKind.allCases.map { kind in
                UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in self?.onNewPane?(kind, axis) }
            })
        })
    }

    private func detach(_ child: UIViewController) {
        guard child.parent === self else { return }
        for (id, gesture) in focusGestures where gesture.view === child.viewIfLoaded {
            gesture.view?.removeGestureRecognizer(gesture)
            focusGestures[id] = nil
        }
        let visible = child.viewIfLoaded?.window != nil
        if visible { child.beginAppearanceTransition(false, animated: false) }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        if visible { child.endAppearanceTransition() }
    }
}
