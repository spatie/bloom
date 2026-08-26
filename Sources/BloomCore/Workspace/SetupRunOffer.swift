import Foundation

/// What a menu should offer for running a workspace's setup script, or nothing at all.
///
/// It lives here rather than in either of the menus that draw it, because there are two of them
/// now: the Workspace menu in the menu bar, and the workspace row's own menu, which is the right
/// click in the sidebar, the right click in Home and the row's hover ellipsis all at once. The
/// answer must not depend on which one you opened. That is the reason `WorkspaceUnreadMark` is in
/// the core as well, and it is the same drift: the row menus were two copies of six items until
/// they disagreed about one workspace.
///
/// ## Absent for one reason, greyed for the other
///
/// The two things that stop a run are not the same kind of no, so they do not get the same answer.
///
/// **No setup script in this repository: no item at all.** A project that has never had one is
/// being offered a row that can never be pressed, on every workspace, for ever, and a permanently
/// dead row teaches nothing. It is the line the Run submenu next to it already draws for a
/// repository with no run scripts.
///
/// **A run already going: the item, greyed.** The reason it cannot be pressed is that it is
/// already doing the thing, and an item that vanished mid run would read as the feature having
/// gone away, at exactly the moment somebody opened the menu to check on it.
///
/// ## Why the title moves
///
/// "Run Setup Again" on a workspace whose own setup header says setup has never run is the app
/// contradicting itself an inch apart, and that is a sentence somebody read before it was fixed.
/// See `WorkspaceModel.hasRunSetup` for what counts as a first time, which includes a run this app
/// was killed in the middle of.
///
/// Pressing the item asks before it runs. See `SetupRunConfirmation`.
public struct SetupRunOffer: Sendable, Hashable {
    /// What the item says.
    public let title: String

    /// Whether it can be pressed now.
    public let isEnabled: Bool

    /// The item to offer for a workspace, or nil when there should be no item.
    ///
    /// The three facts are gathered by the caller rather than read out of a `Workspace`, because
    /// only one of them is on the row. Whether the repository has a setup script is what the
    /// settings file said the last time it was read, and whether a run is going is a fact about a
    /// child process of this app. Both of those are a live `WorkspaceModel`'s to answer.
    public static func offer(
        hasSetupScript: Bool,
        hasRunSetup: Bool,
        isRunning: Bool
    ) -> SetupRunOffer? {
        guard hasSetupScript else { return nil }
        return SetupRunOffer(
            title: hasRunSetup ? "Run Setup Again" : "Run Setup",
            isEnabled: !isRunning
        )
    }
}
