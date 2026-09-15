import Foundation

public extension RemoteCreationRequest {
    static func planned(project: RemoteProject, name: String, prompt: String, mode: WorkspaceStartMode,
                        context: RemoteWorkspaceContext, controls: ComposerControls, baseBranch: String?,
                        checkout: WorkspaceCheckout?, runSetupScript: Bool) throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !prompt.isEmpty else { throw ConnectionRefusal("Enter a workspace name or a prompt.") }
        guard name.utf8.count <= 1_024, prompt.utf8.count <= 200_000 else { throw ConnectionRefusal("Use a shorter workspace name or prompt.") }
        if mode.runsAnAgent {
            guard controls.agentKind.canRunWorkspaces,
                  context.composer.availableAgents?.contains(controls.agentKind) == true,
                  !controls.model.isEmpty else { throw ConnectionRefusal("Choose an installed agent and model.") }
        }
        if case .branch(let branch) = checkout, let holder = branch.inUseBy {
            throw ConnectionRefusal(holder.refusal(branch: branch.name))
        }
        var request = Self(repositoryPath: project.path, name: name.isEmpty ? String(prompt.prefix(80)) : name,
                           agent: controls.agentKind, model: controls.model, effort: controls.effort, permissionMode: controls.permissionMode)
        request.controls = controls
        request.baseBranch = baseBranch
        request.checkout = checkout
        request.runSetupScript = runSetupScript
        // The legacy chat result keeps an explicitly entered name and permits an empty first turn.
        request.mode = mode == .chat ? nil : mode
        request.prompt = mode.runsAnAgent && !prompt.isEmpty ? prompt : nil
        return request
    }
}
