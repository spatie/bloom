import Foundation

/// Which workspaces the checks notification watches, and what counts as news.
///
/// ## The rule this is written from
///
/// **An absence is a fact, and a reader draws the worse conclusion from it.** `DiffScope`
/// carries the same rule for review comments a narrowed scope put out of view: "a comment the
/// reader cannot find reads as a comment that has been thrown away", which is why
/// `strandedNote` exists to say they are safe. A notification that never arrives is the same
/// thing with nothing on screen at all: somebody who switched "Checks finished" on and heard
/// nothing all morning concludes the run has not finished. They are not being careless. They are
/// reading the only evidence they have.
///
/// ## What it was
///
/// The watcher rode on `AppModel.existingModel(for:)`, so a workspace with no `WorkspaceModel`
/// was not watched at all. That is not an edge: nothing has a model until it is opened, so after
/// every relaunch this feature watched **nothing**, and it went on watching nothing at every
/// workspace the morning happened not to start in. The one case it silently excluded is the case
/// it exists for, which is the user not looking.
///
/// The second half was quieter and worse. The announcement needed a previous reading of
/// `.pending`, and the previous readings lived in memory, so a run that finished while Bloom was
/// shut had no previous reading to move from and was never announced. Fixing only the first half
/// would have left that standing on exactly the workspaces the first fix reaches.
///
/// Both halves are one piece of state: the last check state seen for a workspace, written down
/// where it survives a launch. See `lastSeenKey`.
///
/// ## What it costs
///
/// Reading is free and asking is not. Each ask is a `gh` subprocess, so the scope is deliberate:
/// a workspace with no pull request is never asked about, and one whose checks have settled is
/// never asked about again after the reading that settled them. What is left is pull requests
/// with something actually in flight, which is a small multiple of what the old watcher asked
/// and a number bounded by how much CI is running rather than by how many workspaces exist.
///
/// **The known hole, so the next person does not have to find it twice.** A settled workspace
/// whose branch is pushed to again goes back to pending, and nothing here asks it. It is caught
/// anyway for any workspace whose sidebar row is drawn, because `WorkspacePullRequests.track`
/// refreshes those every two minutes on its own and this watcher announces off whatever that
/// leaves behind, at no cost. A workspace in a hidden project, or one scrolled out of a long
/// list, is the case that is genuinely missed.
public enum ChecksWatch {
    /// Where one workspace's last seen check state is written down.
    ///
    /// A settings row per workspace, which is the shape `AskTabs.directoryKey` and
    /// `ComposerControls.contextWindowKey` already use for a fact that belongs to one row and
    /// does not deserve a column. It has to outlive the launch or the second half of the bug
    /// above comes straight back.
    public static func lastSeenKey(workspaceID: WorkspaceID) -> String {
        "checks.lastSeen.\(workspaceID.rawValue)"
    }

    /// Whether this workspace is worth a `gh` call on this pass.
    ///
    /// - Parameter isOnScreen: the workspace the user is looking at, which refreshes itself while
    ///   they read it and is the one workspace a banner would be pointless about. The old watcher
    ///   skipped it for both those reasons and so does this.
    /// - Parameter hasPullRequest: whether anything is known to exist to have checks. A branch
    ///   with no pull request cannot have a check run, so asking is a subprocess spent on a
    ///   certainty.
    /// - Parameter lastSeen: nil has to be asked once, and exactly once, because a baseline is
    ///   what every later answer is a move from. Persisted, so "once" is once per workspace
    ///   rather than once per launch, which is what it used to be.
    public static func polls(
        hasPullRequest: Bool, lastSeen: PullRequest.Checks?, isOnScreen: Bool
    ) -> Bool {
        guard !isOnScreen, hasPullRequest else { return false }
        guard let lastSeen else { return true }
        return lastSeen == .pending
    }

    /// Whether moving from `lastSeen` to `now` is worth interrupting somebody for.
    ///
    /// **Only the transition, never the state**, which is the old watcher's rule kept word for
    /// word: a pull request green since yesterday would otherwise announce itself on every pass.
    /// What changed underneath it is that `lastSeen` survives a relaunch, so the transition is
    /// still there to be found when the run finished while Bloom was shut.
    ///
    /// **Nothing is announced from no previous reading**, and that is a decision rather than
    /// caution. A first reading is a baseline, and announcing off one would mean a fresh database,
    /// or a project added this morning, firing a banner for every pull request in it that happens
    /// to be green. Silent once per workspace is the price of never being wrong in a burst.
    ///
    /// `.unavailable` is not a kind of finishing. It is GitHub refusing this token the checks, and
    /// a banner saying they are done would be a claim nobody made. Same for `.none`, which is a
    /// fact about the repository.
    public static func announces(from lastSeen: PullRequest.Checks?, to now: PullRequest.Checks) -> Bool {
        guard lastSeen == .pending else { return false }
        return now == .passing || now == .failing
    }
}
