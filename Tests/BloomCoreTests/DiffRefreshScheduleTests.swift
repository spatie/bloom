import Foundation
import Testing
@testable import BloomCore

/// Which workspaces the six second diff stat loop asks git about.
///
/// The suite exists because the loop used to ask about all of them, and one pass over one worktree
/// is several `git` processes. Twenty workspaces open therefore meant a steady stream of processes
/// on a machine where nothing was happening, which is what the battery menu was complaining about.
/// What has to stay true is that the workspaces somebody is actually watching keep the old
/// cadence, and that the rest come round in a steady trickle rather than in a burst.
@Suite("Which workspaces the diff stat poll is for")
struct DiffRefreshScheduleTests {
    private func ids(_ count: Int) -> [WorkspaceID] {
        (0..<count).map { WorkspaceID("w\($0)") }
    }

    private func justRefreshed(_ ids: [WorkspaceID], at moment: Date) -> [WorkspaceID: Date] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, moment) })
    }

    @Test("a workspace with an agent writing in it is refreshed on every tick")
    func busyEveryTick() {
        let all = ids(20)
        let now = Date()

        let due = DiffRefreshSchedule.due(
            workspaces: all,
            busy: [all[3], all[7]],
            lastRefreshed: justRefreshed(all, at: now),
            now: now
        )

        #expect(due.contains(all[3]))
        #expect(due.contains(all[7]))
    }

    @Test("a workspace nobody is watching is left alone until it is a minute old")
    func idleIsLeftAlone() {
        let all = ids(20)
        let now = Date()

        let due = DiffRefreshSchedule.due(
            workspaces: all,
            busy: [all[0]],
            lastRefreshed: justRefreshed(all, at: now.addingTimeInterval(-30)),
            now: now
        )

        #expect(due == [all[0]])
    }

    /// The whole point. Twenty idle workspaces at a six second tick and a sixty second age is two
    /// a tick, not twenty in one tick and none in the next nine.
    @Test("the idle ones come round in a trickle rather than a burst")
    func trickle() {
        let all = ids(20)
        let now = Date()

        let due = DiffRefreshSchedule.due(
            workspaces: all,
            busy: [],
            lastRefreshed: justRefreshed(all, at: now.addingTimeInterval(-120)),
            now: now
        )

        #expect(due.count == 2)
    }

    @Test("the oldest go first, so nothing at the back of a queue is starved")
    func oldestFirst() {
        let all = ids(20)
        let now = Date()
        var last = justRefreshed(all, at: now.addingTimeInterval(-61))
        last[all[11]] = now.addingTimeInterval(-600)
        last[all[4]] = now.addingTimeInterval(-300)

        let due = DiffRefreshSchedule.due(
            workspaces: all, busy: [], lastRefreshed: last, now: now
        )

        #expect(due == [all[11], all[4]])
    }

    @Test("the same input answers the same way twice")
    func deterministic() {
        let all = ids(20)
        let now = Date()
        let last = justRefreshed(all, at: now.addingTimeInterval(-61))

        let first = DiffRefreshSchedule.due(
            workspaces: all, busy: [], lastRefreshed: last, now: now
        )
        let second = DiffRefreshSchedule.due(
            workspaces: all, busy: [], lastRefreshed: last, now: now
        )

        #expect(first == second)
    }

    /// A workspace the store has just handed over has no stored count worth trusting, and a
    /// launch is exactly when the numbers on disk are most likely to be a day old.
    @Test("a workspace nothing has asked about yet is due whatever the slice says")
    func neverAsked() {
        let all = ids(20)

        let due = DiffRefreshSchedule.due(
            workspaces: all, busy: [], lastRefreshed: [:], now: Date()
        )

        #expect(due == all)
    }

    /// Rounding down would leave a small sidebar never refreshing anything at all, which is a
    /// worse failure than the one being fixed.
    @Test("a short sidebar still refreshes something")
    func alwaysOne() {
        let all = ids(2)
        let now = Date()

        let due = DiffRefreshSchedule.due(
            workspaces: all,
            busy: [],
            lastRefreshed: justRefreshed(all, at: now.addingTimeInterval(-61)),
            now: now
        )

        #expect(due.count == 1)
    }

    @Test("nothing open asks git nothing")
    func empty() {
        #expect(DiffRefreshSchedule.due(
            workspaces: [], busy: [], lastRefreshed: [:], now: Date()
        ).isEmpty)
    }

    /// One whole round of the idle workspaces takes `idleMaxAge`, which is the property the slice
    /// exists to give. Driven as the loop drives it: a tick, the ones it answered marked as
    /// refreshed, then the next tick.
    @Test("every idle workspace comes round within the age it is allowed to reach")
    func roundTrip() {
        let all = ids(20)
        var last = justRefreshed(all, at: Date(timeIntervalSince1970: 0))
        var now = Date(timeIntervalSince1970: DiffRefreshSchedule.idleMaxAge)
        var seen: Set<WorkspaceID> = []

        for _ in 0..<Int(DiffRefreshSchedule.idleMaxAge / DiffRefreshSchedule.tick) {
            let due = DiffRefreshSchedule.due(
                workspaces: all, busy: [], lastRefreshed: last, now: now
            )
            for id in due {
                seen.insert(id)
                last[id] = now
            }
            now = now.addingTimeInterval(DiffRefreshSchedule.tick)
        }

        #expect(seen.count == all.count)
    }
}
