import BloomCore

/// Moving between workspaces without the pointer.
///
/// It held a second subject, `search`, which matched a workspace by name for the Search screen.
/// That screen is gone and so is this copy of the rule: Home's list is built by `HomeList.build`,
/// which asks `WorkspaceSearch` the same question in the core, over live and archived work in one
/// pass, and there is one answer to it now rather than two lists that had to be kept in step.

extension AppModel {
    func selectNextWorkspace(offset: Int) {
        let ordered = repos.flatMap { workspaces(in: $0) }
        guard !ordered.isEmpty else { return }
        guard let current = selection.workspaceID,
              let index = ordered.firstIndex(where: { $0.id == current }) else {
            selection = .workspace(ordered[0].id)
            return
        }
        let next = (index + offset + ordered.count) % ordered.count
        selection = .workspace(ordered[next].id)
    }

    /// The next workspace with unread agent output, so the user can hop through what finished
    /// while they were elsewhere.
    func selectNextUnread() {
        let ordered = repos.flatMap { workspaces(in: $0) }
        guard let target = ordered.first(where: { $0.unread && $0.id != selection.workspaceID })
            ?? ordered.first(where: \.unread) else { return }
        selection = .workspace(target.id)
    }

    /// Asks for a folder and adds it, which is the whole of what every "Add project" control
    /// does. Four views spelled the pair out themselves.
    func addProjectByAsking() async {
        guard let path = await ProjectFolderPicker.choose() else { return }
        await addRepository(at: path)
    }

}
