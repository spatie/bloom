import BloomCore

/// Back and Forward across workspaces and their tabs: the toolbar's two buttons, the View menu and
/// Control+Tab through `TabCycleShortcut`.
///
/// Recording is driven from the two places a place changes, `selection`'s setter and
/// `WorkspaceTabsStore.select`. What a place is, and how the history walks, is
/// `NavigationHistory` in the core.
extension AppModel {
    func recordNavigationDeparture() {
        guard !isRestoringNavigation,
              let place = NavigationPlace(
                  selection: selection,
                  tab: selectedModel.flatMap { WorkspaceTabsStore.shared.selectedTab(in: $0) }
              ) else { return }
        navigationHistory.recordDeparture(place)
    }

    /// Filed without a tab: a workspace's strip loads after it is selected, so the tab read here
    /// would be a guess (the first terminal, before the chats have arrived). A tab change or the
    /// next departure names it after the strip has loaded.
    func recordNavigation() {
        guard !isRestoringNavigation,
              let place = NavigationPlace(selection: selection, tab: nil) else { return }
        navigationHistory.visit(place)
    }

    func recordTabSelection(_ tab: PaneContent, in workspace: WorkspaceID, leaving previous: PaneContent?) {
        guard !isRestoringNavigation, selection.workspaceID == workspace, tab != previous else { return }
        if let previous { navigationHistory.settle(previous, in: workspace) }
        guard let place = NavigationPlace(selection: selection, tab: tab) else { return }
        navigationHistory.visit(place)
    }

    func canStepNavigation(by step: Int) -> Bool {
        navigationHistory.canMove(step, isReachable: isReachable)
    }

    func stepNavigation(by step: Int) {
        recordNavigationDeparture()
        guard let place = navigationHistory.move(step, isReachable: isReachable) else { return }
        isRestoringNavigation = true
        defer { isRestoringNavigation = false }
        selection = place.selection
        guard let tab = place.tab, let model = selectedModel else { return }
        WorkspaceTabsStore.shared.select(tab, in: model)
    }

    /// Archived workspaces, closed tabs and closed project-free conversations are skipped.
    private func isReachable(_ place: NavigationPlace) -> Bool {
        place.isReachable { id, tab in
            guard workspaces.contains(where: { $0.id == id }) else { return false }
            guard let tab, let model = existingModel(for: id) else { return true }
            return WorkspaceTabsStore.shared.entries(in: model).contains(tab)
        } conversation: { id in
            ask.sessions.contains(where: { $0.id == id })
        }
    }
}
