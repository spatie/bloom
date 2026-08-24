import BloomCore

/// Moving between workspaces without the pointer, and finding one by what was said in it.
///
/// Two subjects in one file because they are the same subject from the reader's side: both are
/// "get me to the workspace I mean", one by walking the list and one by naming it. Neither writes
/// anything but `selection`.

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

    // MARK: - Search

    struct SearchHit: Identifiable {
        var id: WorkspaceID { workspace.id }
        var workspace: Workspace
        var repo: Repo?
        var reason: String
        var isArchived = false
    }

    /// The rule lives in `WorkspaceSearch`, in the core, because Home's filter field and the
    /// Shortcuts entity query ask the same question and used to answer it differently.
    ///
    /// Archived workspaces are searched too, and are passed in rather than read, because the
    /// archived list is a database read and this is called from a view on every keystroke. They
    /// come last: a live workspace is nearly always the one being looked for, and an archived hit
    /// that pushed one down the list would be the search answering a question nobody asked.
    ///
    /// Leaving them out was its own bug. Somebody who archives something and then wants it back
    /// types its name into search first, and search said "No Results" about a workspace whose
    /// branch was sitting on disk.
    func search(_ query: String, alsoSearching archived: [Workspace] = []) -> [SearchHit] {
        let needle = WorkspaceSearch.needle(query)
        guard !needle.isEmpty else { return [] }

        func hits(in list: [Workspace], isArchived: Bool) -> [SearchHit] {
            list.compactMap { workspace in
                let repo = repo(for: workspace)
                guard let reason = WorkspaceSearch.match(
                    workspace: workspace, repo: repo, needle: needle
                ) else { return nil }
                return SearchHit(
                    workspace: workspace, repo: repo, reason: reason, isArchived: isArchived
                )
            }
        }

        return hits(in: workspaces, isArchived: false) + hits(in: archived, isArchived: true)
    }
}
