import BloomCore

/// Stepping through the centre strip, for the two routes that ask: Next Tab and Previous Tab in
/// the View menu, and Option+Tab through `TabCycleShortcut`.
///
/// Here rather than private to `BloomCommands`, because the key monitor is not a view and has no
/// commands body to call into, and two copies of which strip is in front would drift. Which tab is
/// next is `TabCycle` in the core.
extension AppModel {
    func cycleCentreTab(by offset: Int) {
        if selection == .ask {
            if let next = TabCycle.next(from: ask.selectedID, in: ask.sessions.map(\.id), offset: offset) {
                Task { await ask.select(next) }
            }
            return
        }
        guard let workspace = selectedModel else { return }
        WorkspaceTabsStore.shared.selectNextTab(offset: offset, in: workspace)
    }
}
