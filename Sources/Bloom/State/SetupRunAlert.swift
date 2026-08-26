import Foundation
import Observation
import BloomCore

/// The question asked before a workspace's setup script runs, and the one place that asks it.
///
/// Its own type because three controls offer the run: the Workspace menu, a workspace row's own
/// menu, and the "Run setup again" link on a failed setup row in the transcript. A confirmation
/// only one of them raised would be a confirmation the other two walk straight past, which is the
/// argument `CloseSessionAlert` was written on and this follows.
///
/// WHAT it asks is `BloomCore.SetupRunConfirmation`, because a sentence decided inside a view is a
/// sentence nothing can test, and the line about an agent mid turn is a claim about what the run
/// does to a turn in flight.
///
/// A shared presenter rather than an `NSAlert`, for the reason `CloseSessionAlert` gives: a modal
/// run loop stops every other workspace's transcript streaming for as long as the question is up.
/// `RootView` presents `request`.
@MainActor
@Observable
final class SetupRunAlert {
    static let shared = SetupRunAlert()

    /// A run waiting on an answer.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        var model: WorkspaceModel
        var question: SetupRunConfirmation.Question

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    /// Non-nil while the dialog is up.
    var request: Request?

    /// Asks about a run, having read the workspace's state at the moment the item was pressed.
    ///
    /// The facts are captured here rather than read again when the sheet draws, so the question
    /// describes the workspace the reader was looking at. `runSetupAgain` keeps its own guard for
    /// the other half of that gap: a run that started while the question was on screen refuses the
    /// second one rather than doubling it.
    func ask(_ model: WorkspaceModel) {
        guard model.canRunSetup else { return }
        request = Request(
            model: model,
            question: SetupRunConfirmation.question(
                hasRunSetup: model.hasRunSetup, isAgentRunning: model.isRunning
            )
        )
    }
}
