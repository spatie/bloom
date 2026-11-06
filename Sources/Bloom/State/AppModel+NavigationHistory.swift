import BloomCore

/// Back and Forward across workspaces and their tabs: the toolbar's two buttons, the View menu and
/// Control+Tab through `TabCycleShortcut`.
///
/// Recording is driven from the two places a place changes, `selection`'s setter and
/// `WorkspaceTabsStore.select`. What a place is, and how the history walks, is
/// `NavigationHistory` in the core.
extension AppModel {
    /// Filed without a tab: a workspace's strip loads after it is selected, so the tab read here
    /// would be a guess (the first terminal, before the chats have arrived). The tab is named by
    /// `recordTabSelection` the first time the user leaves it.
    func recordNavigation() {
        guard !isRestoringNavigation,
              let place = NavigationPlace(selection: selection, tab: nil) else { return }
        navigationHistory.visit(place)
    }

    func recordTabSelection(_ tab: PaneContent, in workspace: WorkspaceID, leaving previous: PaneContent?) {
        guard !isRestoringNavigation, selection.workspaceID == workspace else { return }
        if let previous { navigationHistory.settle(previous, in: workspace) }
        guard let place = NavigationPlace(selection: selection, tab: tab) else { return }
        navigationHistory.visit(place)
    }

    func canStepNavigation(by step: Int) -> Bool {
        navigationHistory.canMove(step, isReachable: isReachable)
    }

    func stepNavigation(by step: Int) {
        guard let place = navigationHistory.move(step, isReachable: isReachable) else { return }
        isRestoringNavigation = true
        defer { isRestoringNavigation = false }
        selection = place.selection
        guard let tab = place.tab, let model = selectedModel else { return }
        WorkspaceTabsStore.shared.select(tab, in: model)
    }

    /// A workspace archived since, or a tab closed since, is not somewhere to go back to.
    private func isReachable(_ place: NavigationPlace) -> Bool {
        guard case .workspace(let id) = place.selection else { return true }
        guard workspaces.contains(where: { $0.id == id }) else { return false }
        guard let tab = place.tab, let model = existingModel(for: id) else { return true }
        return WorkspaceTabsStore.shared.entries(in: model).contains(tab)
    }
}
