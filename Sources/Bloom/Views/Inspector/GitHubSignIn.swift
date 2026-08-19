import SwiftUI
import Observation
import BloomCore

/// The one way the app asks for GitHub access.
///
/// One presentation rather than a dialog per call site: the sentence, the button and what happens
/// after a successful sign in live here, so a second GitHub action added tomorrow inherits all of
/// it by calling `run`.
///
/// Only a deliberate press ever gets here. Background polls, the sidebar's pull request marks and
/// the inspector's own refresh all ask `GitHubAvailability` and stay quiet when the answer is no,
/// because a dialog nobody asked for, on a schedule, is worse than a missing badge.
@MainActor
@Observable
final class GitHubSignIn {
    static let shared = GitHubSignIn()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// What the probe found: missing, or signed out. Never `.ready`.
        var access: GitHubAvailability.State
        /// Where the login runs. Any directory would do; the worktree the user was looking at
        /// keeps the shell's idea of "here" the same as theirs.
        var directory: String

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    /// Non-nil while the sheet is up. Settable so a `.sheet(item:)` binding can close it.
    var request: Request? {
        didSet {
            guard request == nil else { return }
            // Dropped without going through `finish`, which is what a swipe away or an Escape
            // does. The action the user was trying to take does not run.
            pending = nil
        }
    }

    /// What to do once GitHub answers. See `run` for what may and may not be put in here.
    @ObservationIgnored private var pending: (@MainActor () -> Void)?

    /// Runs `action` when gh can be used, and otherwise raises the sheet and remembers it.
    ///
    /// The action is re-run automatically the moment sign in succeeds, so the user does not have
    /// to find the button they pressed a minute ago. That is only safe because of what callers are
    /// allowed to pass: an action here must be either reversible or a step that ends in a
    /// confirmation. Merging passes "open the merge confirmation", never "merge". Nothing that
    /// cannot be undone may be handed to this.
    func run(directory: String, action: @escaping @MainActor () -> Void) {
        Task {
            let state = await GitHubAvailability.shared.check()
            guard state != .ready else {
                action()
                return
            }
            pending = action
            request = Request(access: state, directory: directory)
        }
    }

    /// Raises the sheet without an action behind it, for a button whose whole purpose is to
    /// connect GitHub.
    func present(directory: String) {
        Task {
            let state = await GitHubAvailability.shared.check(force: true)
            guard state != .ready else { return }
            pending = nil
            request = Request(access: state, directory: directory)
        }
    }

    /// Closes the sheet. On success the remembered action runs, on the same turn of the run loop
    /// the sheet goes away, so the thing the user asked for happens rather than being announced.
    func finish(connected: Bool) {
        let action = pending
        pending = nil
        request = nil
        if connected { action?() }
    }
}
