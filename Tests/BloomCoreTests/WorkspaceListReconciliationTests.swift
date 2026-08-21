import Foundation
import Testing
@testable import BloomCore

/// What the sidebar's list should be when a background refresh answers about a world that has
/// already moved on.
///
/// The suite exists because of a flicker somebody could watch: archive a workspace, the row goes,
/// the row comes back, the row goes again. The archive hides the row before it touches the disk,
/// and the store only hears about the archive several seconds later, so any full re-read landing
/// in between saw a workspace that was still active and put it back on screen.
///
/// Every case here is written from one of the two lists being wrong about the other, which is the
/// only interesting thing about this function.
@Suite("Workspace list reconciliation")
struct WorkspaceListReconciliationTests {
    /// Fixed rather than `Date()`, because the whole function turns on whether two copies of a row
    /// are equal and a clock reading would make every copy a different row.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func workspace(
        _ id: String,
        name: String? = nil,
        additions: Int = 0,
        setupState: SetupState = .succeeded
    ) -> Workspace {
        Workspace(
            id: id,
            repoID: RepoID("repo"),
            name: name ?? id,
            branch: "feature/\(id)",
            path: "/tmp/\(id)",
            baseBranch: "main",
            setupState: setupState,
            createdAt: Self.fixedDate,
            lastActivityAt: Self.fixedDate,
            additions: additions
        )
    }

    private func reconciled(
        held: [Workspace], snapshot: [Workspace], fresh: [Workspace]
    ) -> [Workspace] {
        WorkspaceListReconciliation.reconciled(held: held, snapshot: snapshot, fresh: fresh)
    }

    // MARK: - The bug this was written for

    /// The archive hides the row first and writes to the store last. In between, the store still
    /// answers "active", and the old code assigned that answer over the top of the hidden row.
    @Test("an archive that has not reached the store yet is not undone")
    func archiveInFlightStaysHidden() {
        let alpha = workspace("alpha")
        let beta = workspace("beta")
        let gamma = workspace("gamma")

        let result = reconciled(
            held: [alpha, beta],
            snapshot: [alpha, beta, gamma],
            fresh: [alpha, beta, gamma]
        )

        #expect(result.map(\.id) == ["alpha", "beta"])
    }

    /// Two rows hidden in quick succession, one refresh in flight across both of them. Neither
    /// comes back, and the second archive is not resurrected by the first one's window either.
    @Test("two archives in quick succession both stay hidden")
    func twoArchivesStayHidden() {
        let alpha = workspace("alpha")
        let beta = workspace("beta")
        let gamma = workspace("gamma")

        let result = reconciled(
            held: [alpha],
            snapshot: [alpha, beta, gamma],
            fresh: [alpha, beta, gamma]
        )

        #expect(result.map(\.id) == ["alpha"])
    }

    /// The archive failed and the row was put back by a reload before the refresh answered. The
    /// refresh must not take it away again: the row is genuinely there and the store agrees.
    @Test("a restored row survives a refresh that read the store before it came back")
    func restoredRowSurvives() {
        let alpha = workspace("alpha")
        let gamma = workspace("gamma")

        let result = reconciled(
            held: [alpha, gamma],
            snapshot: [alpha],
            fresh: [alpha, gamma]
        )

        #expect(result.map(\.id) == ["alpha", "gamma"])
    }

    // MARK: - The other direction

    /// Creating a workspace writes it to the store and reloads. A refresh whose read predates the
    /// write used to drop the new row again for the next six seconds.
    @Test("a workspace created while the read was in flight is not dropped")
    func createdRowIsKept() {
        let alpha = workspace("alpha")
        let fresh = workspace("fresh")

        let result = reconciled(
            held: [alpha, fresh],
            snapshot: [alpha],
            fresh: [alpha]
        )

        #expect(result.map(\.id) == ["alpha", "fresh"])
        #expect(result.last == fresh)
    }

    /// A rename writes the new name and reloads. The store's answer was read before that, so it
    /// still spells the old one, and taking it would put the old name back on screen.
    @Test("a rename made during the read is not written over")
    func renameSurvives() {
        let before = workspace("alpha", name: "Old name")
        let after = workspace("alpha", name: "New name")
        let stale = workspace("alpha", name: "Old name", additions: 42)

        let result = reconciled(held: [after], snapshot: [before], fresh: [stale])

        #expect(result.map(\.name) == ["New name"])
        // The stat came with the stale name, so it waits for the next pass rather than dragging
        // the old name back with it.
        #expect(result.map(\.additions) == [0])
    }

    // MARK: - What the refresh is actually for

    /// The whole point of the pass: rows nobody touched take the store's version, which is where
    /// the new diff stats are.
    @Test("a row nobody touched takes the store's version")
    func untouchedRowIsRefreshed() {
        let alpha = workspace("alpha")
        let beta = workspace("beta")
        let refreshedAlpha = workspace("alpha", additions: 120)
        let refreshedBeta = workspace("beta", additions: 3)

        let result = reconciled(
            held: [alpha, beta],
            snapshot: [alpha, beta],
            fresh: [refreshedAlpha, refreshedBeta]
        )

        #expect(result == [refreshedAlpha, refreshedBeta])
    }

    /// The refresh carries more than diff stats: a setup script that finished while the pass ran
    /// writes its outcome onto the row, and the sidebar reads it from there.
    @Test("a setup that finished during the pass is picked up")
    func setupStateIsRefreshed() {
        let running = workspace("alpha", setupState: .running)
        let done = workspace("alpha", setupState: .succeeded)

        let result = reconciled(held: [running], snapshot: [running], fresh: [done])

        #expect(result.map(\.setupState) == [.succeeded])
    }

    /// Nothing moved underneath, so the store's answer is taken whole. This is the ordinary case
    /// and it has to stay exactly as cheap as a plain assignment was.
    @Test("an unchanged list takes the store's answer in full")
    func unchangedListTakesStore() {
        let alpha = workspace("alpha")
        let beta = workspace("beta")
        let fresh = [workspace("alpha", additions: 1), workspace("beta", additions: 2)]

        #expect(reconciled(held: [alpha, beta], snapshot: [alpha, beta], fresh: fresh) == fresh)
    }

    /// Order belongs to the list on screen. The store's `ORDER BY sort_order, created_at` is the
    /// same order until somebody drags a row, and a refresh landing mid drag must not shuffle it
    /// back.
    @Test("order comes from the list as it stands, not from the store")
    func orderComesFromHeld() {
        let alpha = workspace("alpha")
        let beta = workspace("beta")

        let result = reconciled(
            held: [beta, alpha],
            snapshot: [beta, alpha],
            fresh: [alpha, beta]
        )

        #expect(result.map(\.id) == ["beta", "alpha"])
    }

    /// Nothing at all is a real answer, and the empty list is what a first launch holds.
    @Test("an empty list stays empty")
    func emptyStaysEmpty() {
        #expect(reconciled(held: [], snapshot: [], fresh: [workspace("alpha")]).isEmpty)
    }

    // MARK: - A reload landing in the middle of an archive

    /// A reload is a different promise from a refresh: the store is the truth, whatever the list
    /// currently says. The one thing it cannot see is an archive that has not finished writing
    /// itself down, and every other action in the app reloads.
    @Test("a reload does not put back a row whose archive is still running")
    func reloadKeepsArchivingRowHidden() {
        let alpha = workspace("alpha")
        let gamma = workspace("gamma")

        let result = WorkspaceListReconciliation.afterStoreReload(
            fresh: [alpha, gamma], archiving: ["gamma"]
        )

        #expect(result.map(\.id) == ["alpha"])
    }

    /// The archive failed, the workspace is no longer being archived, and the reload is exactly
    /// what has to bring the row back. This is why the set is emptied before that reload runs.
    @Test("a reload brings back a row whose archive has stopped")
    func reloadRestoresAfterFailedArchive() {
        let alpha = workspace("alpha")
        let gamma = workspace("gamma")

        let result = WorkspaceListReconciliation.afterStoreReload(
            fresh: [alpha, gamma], archiving: []
        )

        #expect(result.map(\.id) == ["alpha", "gamma"])
    }

    /// Two archives running at once, which is what pressing Archive twice in a second gives you.
    @Test("two archives running at once both stay out of a reload")
    func reloadKeepsBothArchivingRowsHidden() {
        let alpha = workspace("alpha")
        let beta = workspace("beta")
        let gamma = workspace("gamma")

        let result = WorkspaceListReconciliation.afterStoreReload(
            fresh: [alpha, beta, gamma], archiving: ["beta", "gamma"]
        )

        #expect(result.map(\.id) == ["alpha"])
    }

    /// A restore is the case that stops this from being a filter on the list rather than on the
    /// store: the row is not in the list yet and the reload is what puts it there.
    @Test("a reload still adds a workspace the list has never seen")
    func reloadAddsRestoredWorkspace() {
        let alpha = workspace("alpha")
        let restored = workspace("restored")

        let result = WorkspaceListReconciliation.afterStoreReload(
            fresh: [alpha, restored], archiving: ["gamma"]
        )

        #expect(result.map(\.id) == ["alpha", "restored"])
    }
}
