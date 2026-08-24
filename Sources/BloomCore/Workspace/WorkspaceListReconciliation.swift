import Foundation

/// Works out what the sidebar's list of workspaces should be after a background refresh has read
/// the store, given that the list can have moved on while that read was in flight.
///
/// It exists because of a flicker. Archiving hides the row before any filesystem work starts, on
/// purpose: the decision has already been made and there is nothing left for the user to wait
/// for. But the store does not learn about the archive until the very end, after the safety
/// report, the archive script, `git worktree remove` and the branch delete, which on a real
/// project is several seconds. Anything that re-read the whole list during that window read a
/// workspace that was still `active`, and assigning that list back put the row on screen again.
/// It then left a second time when the archive finished, so the row went, came back, and went.
/// Measured on a 120,000 file worktree: hidden at 1.9s, back at 6.1s, gone again at 6.8s.
///
/// The rule that fixes it is one sentence. A refresh is authoritative about what is IN a
/// workspace row and never about which rows exist.
///
/// Membership and order therefore come from `held`, the list as it stands right now, which is the
/// only version that knows about a decision the user made a moment ago. That cuts both ways: a
/// row removed while the read was in flight is not put back, and a row added while the read was
/// in flight is not taken away. The second half matters as much as the first. Creating a
/// workspace writes it to the store and reloads, and a refresh that had read the store one moment
/// earlier used to drop the new row again for the next six seconds.
///
/// `snapshot` is what `held` looked like when the read began, and it is what decides whether a
/// given row may be updated at all. A row nobody has touched since takes the store's version,
/// which is the whole point of the refresh: new diff stats, a setup that has finished. A row that
/// changed in memory during the read keeps the version it has, because the store's answer was
/// read before that change and putting it back would undo it. A rename is the case to picture: it
/// writes the new name and reloads, and without this check the next refresh would spend six
/// seconds insisting on the old one.
public enum WorkspaceListReconciliation {
    /// - Parameters:
    ///   - held: the list as it stands now, after whatever happened during the read.
    ///   - snapshot: the same list as it stood when the read began.
    ///   - fresh: what the store just answered.
    public static func reconciled(
        held: [Workspace],
        snapshot: [Workspace],
        fresh: [Workspace]
    ) -> [Workspace] {
        let wasHeld = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let isStored = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return held.map { row in
            guard let stored = isStored[row.id], wasHeld[row.id] == row else { return row }
            return stored
        }
    }

    /// What a full reload should publish.
    ///
    /// A reload is the app saying the store is the truth now, and it has to stay that way: it is
    /// how a restored workspace comes back and how a newly created one first appears, so it
    /// cannot take its membership from the list the way a refresh does.
    ///
    /// The one thing the store is not yet right about is an archive that is still running.
    /// `AppModel.performArchive` hides the row before it touches the disk and the row only
    /// becomes `archived` in the store at the very end, so a reload for something else entirely,
    /// a rename finishing, a workspace being pinned, an automatic name arriving, used to put the
    /// row back for the rest of the archive. Measured with an archive script that slept ten
    /// seconds: hidden, then back in the list at the reload, then gone again when the archive
    /// finished.
    ///
    /// `archiving` is emptied before the reload that follows a failed archive, which is what lets
    /// that reload put the row back where it belongs.
    public static func afterStoreReload(fresh: [Workspace], archiving: Set<WorkspaceID>) -> [Workspace] {
        guard !archiving.isEmpty else { return fresh }
        return fresh.filter { !archiving.contains($0.id) }
    }
}
