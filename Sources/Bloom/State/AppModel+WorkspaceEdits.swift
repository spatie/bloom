import BloomCore

/// The small changes a person makes to a workspace that is already there: its name, its pin, its
/// colour, and whether it is showing as unread.
///
/// One subject, and the thing they share is the rule that makes them safe. Every one of these
/// goes through `Store.update(workspaceID:)` rather than `upsert`, because a workspace row has a
/// diff stat refresh writing to it every six seconds and an agent turn writing to it for ten
/// minutes, and a whole-value write from a panel somebody sat in for a minute rolled both of
/// those back. See `Tests/BloomCoreTests/WorkspaceWriteIsolationTests.swift`.

extension AppModel {
    func rename(_ workspace: Workspace, to name: String) async {
        guard let store, !name.isEmpty else { return }
        _ = try? await store.update(workspaceID: workspace.id) { $0.name = name }
    }

    func togglePinned(_ workspace: Workspace) async {
        guard let store else { return }
        // Toggled against the stored row rather than against the copy this view was handed,
        // so two presses in quick succession cannot both write the same value.
        _ = try? await store.update(workspaceID: workspace.id) { $0.pinned.toggle() }
    }

    /// Clears the mark that says a turn finished while you were not looking.
    ///
    /// The rule, in full, because three things now depend on it: the Dock badge, the menu bar
    /// item and the weight of a project's name in the sidebar.
    ///
    /// `TranscriptModel.notifyFinished` SETS the flag when a turn ends and the workspace is not
    /// the selected one. This clears it when the workspace's transcript comes on screen, from
    /// `WorkspaceModel.onAppear`. The two are exact duals: the flag means "this finished while it
    /// was not in front of you", and it goes the moment it is.
    ///
    /// Two consequences that have each been mistaken for a bug.
    ///
    /// The first is that launching clears it for the restored workspace. `restoreLastSelection`
    /// reopens the window on the workspace it was last on, that workspace's transcript is what
    /// the window paints, and the finished turn is the last thing in it. Confirmed by capture: a
    /// workspace with the flag set that is not the restored one keeps it, the restored one does
    /// not. That is the same rule as any other selection, and the alternative is worse: the badge
    /// would count the workspace whose transcript is filling the window, and the only way to
    /// clear it would be to navigate away and back.
    ///
    /// The second is that the flag includes turns that failed or were cancelled. That is
    /// deliberate. An agent that fell over is still something waiting for a person, and it is the
    /// one most worth being told about; a mark that counted only successes would go quiet exactly
    /// when something went wrong.
    func markRead(_ workspace: Workspace) async {
        guard workspace.unread else { return }
        await setUnread(workspace, false)
    }

    /// The mark set by hand, from a workspace row's context menu, in either direction.
    ///
    /// **What happens when you mark the workspace you are looking at.** The mark sticks. It is
    /// worth writing down because the opposite was the obvious guess and it would have made the
    /// item useless. Nothing re-clears the flag while a workspace stays on screen: the only clear
    /// is `WorkspaceModel.onAppear`, and the centre column runs that from a `.task(id:)` keyed on
    /// the workspace id, so it fires when the window ARRIVES on a workspace and not again while it
    /// sits there. The row goes heavy under the pointer, the badge counts it, and it is still
    /// there when you come back. `TranscriptModel.markAllRead` is a different mark on a different
    /// row (`Session.lastReadSeq`, which is where the transcript reopens) and it does not touch
    /// this one.
    ///
    /// The one thing that does clear it is a turn FINISHING in that workspace while you are still
    /// looking at it, because `TranscriptModel.notifyFinished` writes `unread` either way. That is
    /// correct rather than a leak: how the turn went is newer information than a reminder set
    /// before it ended, and you were there to see it.
    ///
    /// That is the whole reason this exists in the direction it does. "Mark as Unread" means
    /// "remind me to come back to this", and a reminder that clears itself while you are still
    /// standing in front of it is not a reminder.
    ///
    /// Narrow, like every other writer of this table: `update` re-reads the row inside the actor
    /// and changes the one column named. A whole `Workspace` value written from a menu that has
    /// been open for a few seconds is the bug `Store.update` was written for, three times over.
    func setUnread(_ workspace: Workspace, _ unread: Bool) async {
        guard let store else { return }
        _ = try? await store.update(workspaceID: workspace.id) { $0.unread = unread }
    }

    /// The colour on a workspace row, or nil to take it off.
    ///
    /// Stored as the hex rather than as a position in `WorkspaceColour.all`, so reordering that
    /// list later cannot recolour rows somebody already marked.
    func setColour(_ workspace: Workspace, to hex: String?) async {
        guard let store else { return }
        _ = try? await store.update(workspaceID: workspace.id) { $0.colour = hex }
    }
}
