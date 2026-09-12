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
final class WorkspaceToolDeckController: UIViewController {
    private(set) var tabs: [WorkspaceToolTab] = []
    private(set) var selectedID: UUID?
    var onEmpty: (() -> Void)?
    var onSelection: (() -> Void)?
    var onNewPane: ((PaneKind, SplitAxis?) -> Void)?
    var onRename: ((WorkspaceToolPane) -> Void)?
    var onClosePane: ((WorkspaceToolPane) -> Void)?
    var onEndTerminal: ((WorkspaceToolPane) -> Void)?
    /// Temporarily present the focused leaf without changing the saved split or selected tab.
    var focusesSinglePane = false {
        didSet {
            guard focusesSinglePane != oldValue, isViewLoaded else { return }
            renderSelection()
            view.setNeedsLayout()
        }
    }
    private let selector = UISegmentedControl()
    private let leafSelector = UISegmentedControl()
    private let tabScroll = UIScrollView()
    private let canvas = UIView()
    private let menu = UIButton(type: .system)
    private let tabHeader = UIStackView()
    private var tabHeaderHeight: NSLayoutConstraint?
    private var shouldRevealSelectedTab = false
    private var previousTabWidth: CGFloat = 0
    private var leafHeight: NSLayoutConstraint?
    private var dividers: [UIView] = []
    private var installed: [String: WorkspaceToolPane] = [:]
    private var compactSplit = false
    private var showsFocusedPaneOnly: Bool { compactSplit || focusesSinglePane }
    var selectedTab: WorkspaceToolTab? { tabs.first { $0.id == selectedID } }
    var selectedPane: WorkspaceToolPane? { selectedTab.flatMap { $0.contents[$0.layout.focus] } }
    var allPanes: [WorkspaceToolPane] { tabs.flatMap(\.panes) }
    var showingPaneIDs: Set<String> { Set(installed.keys) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        selector.addAction(UIAction { [weak self] _ in
            guard let self, tabs.indices.contains(selector.selectedSegmentIndex) else { return }
            select(tabs[selector.selectedSegmentIndex].id)
        }, for: .valueChanged)
        leafSelector.addAction(UIAction { [weak self] _ in
            guard let self, let tab = selectedTab, tab.panes.indices.contains(leafSelector.selectedSegmentIndex) else { return }
            tab.layout.setFocus(tab.panes[leafSelector.selectedSegmentIndex].id)
            renderSelection()
            updateMenu()
            onSelection?()
        }, for: .valueChanged)
        selector.accessibilityLabel = "Workspace tabs"
        leafSelector.accessibilityLabel = "Split panes"
        tabScroll.showsHorizontalScrollIndicator = false
        tabScroll.addSubview(selector)
        menu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menu.showsMenuAsPrimaryAction = true
        menu.accessibilityLabel = "Tab and split options"
        [tabScroll, menu].forEach { tabHeader.addArrangedSubview($0) }
        tabHeader.spacing = 8
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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            menu.widthAnchor.constraint(equalToConstant: 44)
        ])
        refreshTabs()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        selector.frame = CGRect(x: 0, y: 0, width: max(tabScroll.bounds.width, CGFloat(tabs.count) * 140), height: 44)
        tabScroll.contentSize = selector.bounds.size
        revealSelectedTab()
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
        selector.removeAllSegments()
        for (index, tab) in tabs.enumerated() { selector.insertSegment(withTitle: tab.title, at: index, animated: false) }
        selector.selectedSegmentIndex = tabs.firstIndex { $0.id == selectedID } ?? UISegmentedControl.noSegment
        // A single browser or terminal already supplies its own toolbar. The workspace menu
        // keeps pane actions available without adding a redundant title row above it.
        tabHeaderHeight?.constant = tabs.count > 1 ? 44 : 0
        tabHeader.isHidden = tabs.count <= 1
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
        let ids = Set(visible.map(\.id))
        for (id, pane) in installed where !ids.contains(id) { detach(pane.content); installed[id] = nil }
        for pane in visible where installed[pane.id] == nil {
            let visible = view.window != nil
            if visible { pane.content.beginAppearanceTransition(true, animated: false) }
            addChild(pane.content)
            canvas.addSubview(pane.content.view)
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
        dividers.forEach { $0.removeFromSuperview() }; dividers.removeAll()
        guard let tab = selectedTab else { return }
        if showsFocusedPaneOnly {
            installed[tab.layout.focus]?.content.view.frame = canvas.bounds
            return
        }
        let geometry = tab.layout.geometry(in: canvas.bounds.size, dividerThickness: 1)
        for pane in geometry.panes { installed[pane.pane]?.content.view.frame = pane.frame }
        for divider in geometry.dividers {
            let rule = UIView(frame: divider.frame)
            rule.backgroundColor = BloomTheme.border
            rule.accessibilityElementsHidden = true
            canvas.addSubview(rule); dividers.append(rule)
        }
    }

    private func revealSelectedTab() {
        let resized = previousTabWidth != tabScroll.bounds.width
        previousTabWidth = tabScroll.bounds.width
        guard shouldRevealSelectedTab || resized, tabScroll.bounds.width > 0 else { return }
        shouldRevealSelectedTab = false
        guard tabs.count > 1, selector.selectedSegmentIndex != UISegmentedControl.noSegment else { return }
        let width = selector.bounds.width / CGFloat(tabs.count)
        let frame = CGRect(x: CGFloat(selector.selectedSegmentIndex) * width, y: 0, width: width, height: 44)
        tabScroll.scrollRectToVisible(frame, animated: false)
    }

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

    private func updateMenu() { menu.menu = paneActionsMenu }

    private func detach(_ child: UIViewController) {
        guard child.parent === self else { return }
        let visible = child.viewIfLoaded?.window != nil
        if visible { child.beginAppearanceTransition(false, animated: false) }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        if visible { child.endAppearanceTransition() }
    }
}
