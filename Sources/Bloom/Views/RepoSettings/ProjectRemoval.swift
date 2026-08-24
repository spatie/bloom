import Foundation
import BloomCore

/// The dialog `ProjectRemoval` is worn in.
///
/// The words are in `BloomCore`, where they can be tested; only the shape is here, because
/// `Confirmation` is a piece of this app's chrome and the core does not know about dialogs. Every
/// caller goes through `AppModel.projectRemoval(_:)` rather than assembling the arguments itself,
/// which is what stopped the three of them drifting the first time.
extension ProjectRemoval {
    static func confirmation(
        for repo: Repo, workspaces: [Workspace], runningAgents: Int
    ) -> Confirmation {
        Confirmation(
            title: "Remove \(repo.name)?",
            message: consequences(workspaces: workspaces, runningAgents: runningAgents),
            confirmLabel: "Remove Project",
            cancelLabel: "Cancel"
        )
    }
}
