import Foundation
import Testing
@testable import BloomCore

/// Work that must not be run twice at once, however many callers ask for it.
///
/// The bug behind this type is worth restating, because it is what the last two tests here are
/// reconstructions of. `TranscriptModel.load()` had two callers and no way to tell them apart: the
/// flag it guarded on was only raised on its last line, so both got past it. While the read was one
/// synchronous block that was harmless, since the second reader rebuilt what the first had built.
/// Once there was an await in the middle of the block, both readers emptied the row list and then
/// both filled it, and eight messages became sixteen rows carrying eight identifiers twice over.
@Suite("Single flight")
struct SingleFlightTests {
    /// A counter the work can write to. A class rather than a captured local, because the work is
    /// handed to a task and a local would be copied into it.
    @MainActor
    private final class Runs {
        var started = 0
        var finished = 0
        var rows: [Int] = []
    }

    @MainActor
    @Test("two callers arriving together run the work once between them")
    func coalescesConcurrentCallers() async {
        let flight = SingleFlight()
        let runs = Runs()

        async let first: Void = flight.run { await Self.suspendingWork(runs) }
        async let second: Void = flight.run { await Self.suspendingWork(runs) }
        _ = await (first, second)

        #expect(runs.started == 1)
        #expect(runs.finished == 1)
    }

    @MainActor
    @Test("the caller that waits does not return before the work has finished")
    func theSecondCallerWaitsForTheFirst() async {
        let flight = SingleFlight()
        let runs = Runs()

        async let first: Void = flight.run { await Self.suspendingWork(runs) }
        async let second: Void = flight.run { await Self.suspendingWork(runs) }
        _ = await (first, second)

        // Both calls have returned, so the one run they share is over rather than merely started.
        // A second caller handed a half done job is the whole of what went wrong in the transcript.
        #expect(runs.finished == 1)
    }

    @MainActor
    @Test("a run started after the last one finished is a run of its own")
    func runsAgainOnceTheFirstIsOver() async {
        let flight = SingleFlight()
        let runs = Runs()

        await flight.run { await Self.suspendingWork(runs) }
        await flight.run { await Self.suspendingWork(runs) }

        #expect(runs.started == 2)
        #expect(runs.finished == 2)
    }

    @MainActor
    @Test("work that suspends halfway is not left interleaved with a second run of itself")
    func doesNotInterleaveTheHalvesOfTheWork() async {
        let flight = SingleFlight()
        let runs = Runs()

        // The shape of `TranscriptModel.load()` on the day it broke: empty the list, suspend, then
        // fill it. Two of these running at once empty and empty and then fill and fill.
        let rebuild: @Sendable @MainActor () async -> Void = {
            runs.rows = []
            await Task.yield()
            runs.rows.append(contentsOf: [0, 1, 2, 3, 4, 5, 6, 7])
        }

        async let first: Void = flight.run(rebuild)
        async let second: Void = flight.run(rebuild)
        _ = await (first, second)

        #expect(runs.rows == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(Set(runs.rows).count == runs.rows.count)
    }

    @MainActor
    @Test("waiting returns at once when nothing is under way")
    func waitingOnNothingReturnsAtOnce() async {
        let flight = SingleFlight()
        await flight.wait()
    }

    @MainActor
    @Test("waiting returns only once the run under way has finished")
    func waitingFollowsTheRunUnderWay() async {
        let flight = SingleFlight()
        let runs = Runs()

        async let running: Void = flight.run { await Self.suspendingWork(runs) }
        // Started off the same actor, so it is queued behind the call above and finds the run in
        // the slot. This is the position `TranscriptModel.appendLatestMessages` is in when the
        // agent answers before the history has landed.
        async let waiting: Void = flight.wait()
        _ = await (running, waiting)

        #expect(runs.finished == 1)
    }

    /// Work with a suspension in it, which is the only kind that can be raced.
    @MainActor
    private static func suspendingWork(_ runs: Runs) async {
        runs.started += 1
        await Task.yield()
        runs.finished += 1
    }
}
