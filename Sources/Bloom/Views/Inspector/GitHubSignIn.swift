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
        /// What the probe found: missing, or signed out. `.ready` only from Settings, to sign in
        /// again or switch account.
        var access: GitHubAvailability.State
        /// Where the login runs. Any directory would do; the worktree the user was looking at
        /// keeps the shell's idea of "here" the same as theirs.
        var directory: String
        var forge: Forge = .gitHub
        /// The GitLab host to sign in to. Nil on GitHub, and from Settings for any host.
        var host: String?
        var purpose: Purpose = .action

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    /// Why the sheet is up, which is what its sentence and its command depend on.
    enum Purpose {
        /// An action that needed access, which runs once it is there.
        case action
        /// Settings' install, sign in and reconnect.
        case connect
        /// Settings' `gh auth switch`.
        case switchAccount
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
            // A GitLab project never needs gh, and says what glab needs through its own reads.
            guard await ForgeResolver.forge(for: directory) == .gitHub else {
                action()
                return
            }
            let state = await GitHubAvailability.shared.check()
            guard state != .ready else {
                action()
                return
            }
            pending = action
            request = Request(access: state, directory: directory)
        }
    }

    /// For a button whose whole purpose is to connect GitHub. Nothing happens if it turns out
    /// GitHub is already connected, which is the honest outcome: the state everything reads is
    /// updated by the probe, so whatever offered this button goes away on its own.
    func present(directory: String) {
        run(directory: directory) {}
    }

    /// glab's state on the host asked about, else this directory's, else any host for a sign in
    /// from Settings, with the accounts read again so it shows in Settings and in
    /// `gitlab_username` without a relaunch.
    func gitLabAccess(in directory: String, host: String?) async -> GitHubAvailability.State {
        guard GitLab.isInstalled else { return .notInstalled }
        var asked = host
        if asked == nil { asked = await GitLab.host(in: directory) }
        await GitLabIdentity.resolve(force: true)
        guard let asked else { return GitLabIdentity.usernames.isEmpty ? .signedOut : .ready }
        return GitHubAvailability.State(await GitLab.access(host: asked))
    }

    /// The GitLab sheet, for a read that failed because glab is missing or signed out.
    func presentGitLab(directory: String, host: String?, access: GitHubAvailability.State) {
        pending = nil
        request = Request(access: access, directory: directory, forge: .gitLab, host: host)
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
