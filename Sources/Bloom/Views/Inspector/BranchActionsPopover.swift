import SwiftUI
import BloomCore

enum PullRequestCreationRoute: String, CaseIterable {
    case agent
    case direct

    func label(on forge: Forge) -> String {
        switch self {
        case .agent: "Ask agent to create \(forge.shortRequest)"
        case .direct: "Commit and create \(forge.shortRequest) with \(forge.name) CLI"
        }
    }
}

/// Chooses who prepares the branch and opens its pull request.
struct BranchActionsPopover: View {
    let model: WorkspaceModel
    let onCreatePullRequest: (PullRequestCreationRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var route = PullRequestCreationRoute.agent

    var body: some View {
        ConfirmationPopover(
            title: "Create \(model.forge.request)?",
            confirmLabel: "Create \(model.forge.shortRequest)",
            tint: Palette.controlAccent,
            canConfirm: route == .agent || (model.gitHubReadiness.isUsable && !model.isRunning),
            onConfirm: {
                dismiss()
                onCreatePullRequest(route)
            },
            onCancel: { dismiss() },
            width: 380
        ) {
            Picker("Create using", selection: $route) {
                ForEach(PullRequestCreationRoute.allCases, id: \.self) { choice in
                    Text(choice.label(on: model.forge)).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)

            if route == .direct {
                Text("Bloom stages and commits all local changes as “\(model.workspace.name)”, pushes the branch, then opens a \(model.forge.request) with \(model.forge.cli).")
                    .foregroundStyle(.secondary)
                if !model.gitHubReadiness.isUsable {
                    Text("Connect \(model.forge.name) to use the direct route.")
                        .foregroundStyle(Palette.negative)
                } else if model.isRunning {
                    Text("Wait for the agent to finish before committing directly.")
                        .foregroundStyle(Palette.negative)
                }
            } else {
                Text("The agent will prepare the commits, push, and create the \(model.forge.request) using this project's instructions.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
