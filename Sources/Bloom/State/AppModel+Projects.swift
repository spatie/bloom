import BloomCore

/// Projects: adding one, removing one, and the ordering of the sidebar's headers.
///
/// A project is a git repository the owner pointed Bloom at. It owns workspaces and nothing else,
/// which is why this is a subject of its own rather than half of the workspace file: everything
/// here is about a repository on disk and a row in `repos`, and nothing here cuts a worktree.
///
/// `reorderProjects` is deliberately NOT here. It writes `repos`, and `AppModel.swift` says in its
/// own header that it is the only writer of that list.

extension AppModel {
    /// Adds a folder as a project, or offers to make it into one.
    ///
    /// A folder that is not a git repository used to end here, in an alert reading "... is not a
    /// git repository", which is true and useless: it names the problem and offers nothing. Every
    /// route in now asks the same questions first, and they are `FolderVerdict.of` in the core,
    /// which `project_add` over the bridge asks too. A repository is added. A folder that has no
    /// business becoming one, or a repository that has no business being a project, is refused
    /// with a reason. Anything else is offered `ProjectSetupSheet`.
    ///
    /// - Parameter surface: which window asked, so the offer appears on that one. See
    ///   `ProjectSetupSurface`.
    func addRepository(at path: String, presentedIn surface: ProjectSetupSurface = .main) async {
        guard manager != nil else { return }

        let facts = await RepositoryStarter.inspect(path)
        switch FolderVerdict.of(facts) {
        case .alreadyRepository(let root):
            await addKnownRepository(at: root)

        case .refuse(let refusal):
            alert = BloomAlert(title: "Bloom will not add this folder", message: refusal.sentence)

        case .offer:
            await offerToStartRepository(at: facts.path, presentedIn: surface)
        }
    }

    /// The original path, for a folder git already recognises.
    ///
    /// It hands the row back, because one caller needs it: a project that was just created goes
    /// straight on to its first workspace, and the create window has to be told which project.
    @discardableResult
    private func addKnownRepository(at path: String) async -> Repo? {
        guard let manager else { return nil }
        do {
            return try await manager.addRepository(at: path)
        } catch {
            alert = BloomAlert(title: "Could not add that folder", message: error.readableMessage)
            return nil
        }
    }

    /// Registers what `StartProjectView` ended with, and hands the row back so a first workspace
    /// can follow where there is one to start.
    ///
    /// The same call as adding a folder somebody chose, deliberately: by the time this runs the
    /// folder is a git repository with a commit in it, whether Bloom made it a moment ago or found
    /// it that way, which is exactly what `addRepository` takes. A second registration path is how
    /// two lists of rules start disagreeing. See `FolderVerdict`, which is the last thing to have
    /// had that happen to it.
    func addStartedProject(at path: String) async -> Repo? {
        await addKnownRepository(at: path)
    }

    /// Walks the folder off the main actor and raises the offer.
    ///
    /// The walk is what the dialog's promises are made of, and a folder with a large
    /// `node_modules` in it takes long enough to count that doing it here would freeze the window
    /// between the file panel closing and the sheet appearing.
    private func offerToStartRepository(at path: String, presentedIn surface: ProjectSetupSurface) async {
        let contents = await Task.detached { RepositoryStarter.scan(path) }.value
        let identityProblem = await RepositoryStarter.identityProblem(at: path)

        ProjectSetup.shared.present(ProjectSetup.Request(
            path: path,
            contents: contents,
            surface: surface,
            identityProblem: identityProblem
        ))
    }

    /// Called by `ProjectSetupSheet` once the folder really is a repository.
    func finishProjectSetup(_ path: String?) async {
        ProjectSetup.shared.dismiss()
        guard let path else { return }
        await addKnownRepository(at: path)
    }

    /// The one question about removing a project, built from what this window knows.
    ///
    /// Assembled here rather than at each of the three places that ask it. They used to filter the
    /// workspace list themselves and now have a second argument to get right as well, and three
    /// copies of a filter is how the three of them worded the consequence differently in the first
    /// place. See `ProjectRemoval`.
    func projectRemoval(_ repo: Repo) -> Confirmation {
        let mine = workspaces.filter { $0.repoID == repo.id }
        return ProjectRemoval.confirmation(
            for: repo,
            workspaces: mine,
            runningAgents: mine.count { isRunning($0) }
        )
    }

    /// Forgets a project, and stops its agents first.
    ///
    /// The stop is the whole of the fix for a modal that read "Could not store a system row:
    /// FOREIGN KEY constraint failed". Removing a project deletes its workspaces, their sessions
    /// and their transcripts by cascade, and this used to do that with the agents still running:
    /// the next row a turn wrote had no session left to hang from, the foreign key refused it, and
    /// the runner reported a database fault for something the owner had just asked for.
    ///
    /// Awaited rather than signalled, unlike the archive path, because there is no worktree left
    /// to protect here and no hurry: nothing is on screen waiting for this, and a process that is
    /// actually gone before the rows go is a race that never has to be diagnosed afterwards. It is
    /// still only most of the race, which is why `AgentRunner.report` can tell the two apart: a
    /// runner whose process has exited can still be draining the lines it already read.
    ///
    /// The models are dropped as well as torn down. A `WorkspaceModel` left in the table for a
    /// workspace whose row no longer exists is a second writer with nothing to write to.
    func removeRepository(_ repo: Repo) async {
        guard let store else { return }

        // Every model this project has, not only the rows the sidebar is drawing: `workspaces`
        // holds active ones, and an archived workspace that is still open in a tab has a model too.
        let doomed = workspaceModels.filter { $0.value.workspace.repoID == repo.id }
        // Signalled first and waited for second, exactly as `shutdownEverything` does it, so a
        // project with four running agents costs one SIGTERM escalation rather than four in a row.
        for (_, model) in doomed { model.stopEverything() }
        for (id, model) in doomed {
            await model.shutdown()
            model.teardown()
            workspaceModels[id] = nil
        }

        do {
            try await store.deleteRepo(id: repo.id)
        } catch {
            alert = BloomAlert(
                title: "Could not remove the project",
                message: TranscriptStanding.complaint(about: error)
            )
        }
    }

    func toggleCollapsed(_ repo: Repo) async {
        guard let store else { return }
        // Toggled against the stored row rather than against the copy the sidebar was drawn
        // from, so the disclosure cannot also write back a project's name, colour or icon.
        _ = try? await store.update(repoID: repo.id) { $0.collapsed.toggle() }
    }

    /// Takes a project out of the sidebar's list, or puts it back.
    ///
    /// Nothing else happens, and that is the whole design. The selection is not moved, no chat is
    /// closed, no agent is stopped, and every workspace this project has goes on running and goes
    /// on appearing on Home, in search, in the menu bar and in Shortcuts. See `ProjectVisibility`.
    ///
    /// Hiding the project of the workspace on screen therefore leaves that workspace exactly where
    /// it was, with its row simply not drawn. That is not a new state for this pane to be in: the
    /// workspace filter has always been able to hide the selected row, and the list has always
    /// carried on showing what is selected regardless.
    ///
    /// Toggled against the stored row rather than against the copy the sidebar was drawn from, so
    /// this cannot also write back a project's name, colour or icon. Same reason as
    /// `toggleCollapsed` above, and the bug is in `Store.update(repoID:)`.
    func toggleHidden(_ repo: Repo) async {
        guard let store else { return }
        _ = try? await store.update(repoID: repo.id) { $0.hidden.toggle() }
    }

    func rename(_ repo: Repo, to name: String) async {
        guard let store, !name.isEmpty else { return }
        _ = try? await store.update(repoID: repo.id) { $0.name = name }
    }
}
