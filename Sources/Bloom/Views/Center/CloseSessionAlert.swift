import SwiftUI
import Observation
import BloomCore

/// The question asked before a session that is mid turn is closed.
///
/// Closing a session stops its agent, and a turn that is stopped halfway is work that has already
/// been paid for and cannot be picked up again, which is exactly the thing quitting asks about in
/// `BloomAppDelegate.confirmQuit`. It is the same shape here for the same reason.
///
/// Its own type because two places close a session, the tab's close button and Cmd+W, and a
/// warning that only one of them asked would be a warning the keyboard walks straight past. Both
/// of them hand the session over here and are done: what closing a session finishes with is one
/// path rather than one per caller, which is how Cmd+W used to leave behind the pane the closed
/// chat had been showing in.
///
/// A shared presenter rather than an `NSAlert`, on the model of `ProjectSetup`. `runModal()` is
/// not "this window is busy", it is "this process is busy": it runs a modal run loop, and every
/// other workspace's transcript stops streaming for as long as the question is on screen. This is
/// the most-asked question in the app, and freezing every other agent to ask it is a bug in an app
/// whose whole point is several of them working at once. `RootView` presents `request`.
@MainActor
@Observable
final class CloseSessionAlert {
    static let shared = CloseSessionAlert()

    /// A session that is still working, waiting on an answer.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        var session: Session
        var model: WorkspaceModel

        /// Named rather than "Are you sure?", so the question can be answered without opening the
        /// window behind it to find out which session it is about.
        var title: String {
            let name = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "This session is still working" : "\(name) is still working"
        }

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    static let message = """
        Closing it stops the agent. The turn it is in the middle of will not be finished, and it \
        cannot be resumed.
        """

    /// Non-nil while the dialog is up.
    var request: Request?

    /// Closes the session, asking first when there is a turn to lose. An idle session is never
    /// asked about: a dialog that appears when there is nothing to lose is a dialog that stops
    /// being read.
    func close(_ session: Session, in model: WorkspaceModel) {
        guard model.isRunning(session) else { return perform(session, in: model) }
        request = Request(session: session, model: model)
    }

    func confirm() {
        guard let request else { return }
        self.request = nil
        perform(request.session, in: request.model)
    }

    func cancel() {
        request = nil
    }

    private func perform(_ session: Session, in model: WorkspaceModel) {
        Task {
            await model.closeSession(session)
            // A no-op unless the chat was a pane of some tab. A tab down to one pane dissolves
            // into whatever is left rather than taking the column with it, and a tab named after
            // this conversation is re-filed under one of its other panes. See `TabSurgery`.
            WorkspaceTabsStore.shared.forget(.chat(session.id), workspaceID: model.workspace.id)
        }
    }
}
