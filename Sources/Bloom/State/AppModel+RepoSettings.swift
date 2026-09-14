import BloomCore

/// Saving project settings must update the Run menu without a sidebar selection change.
extension AppModel {
    func refreshSettings(for repoID: RepoID, savedPaths: [String]) {
        // A setting inherited from a home file can be shared by several projects.
        let changedHome = !Set(savedPaths).isDisjoint(with: SettingsLoader.homePaths())
        for model in workspaceModels.values where changedHome || model.workspace.repoID == repoID {
            model.refreshSettings()
        }
    }
}
