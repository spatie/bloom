import Foundation
import Testing
@testable import BloomCore

/// A run script has no exit status, so whether it is running is read off who holds the terminal,
/// one poll at a time, and no single reading is believed.
@Suite("Run script activity")
struct RunScriptActivityTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test("A typed command is running from the moment it was typed")
    func typedIsRunning() {
        var activity = RunScriptActivity()
        #expect(activity.state == .idle)
        activity.typed(at: at(0))
        #expect(activity.state == .running(since: at(0)))
    }

    @Test("Idle readings while the shell reads its rc files are not a stop")
    func idleBeforeTheCommandStarts() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: false, at: at(1))
        activity.observe(busy: false, at: at(2))
        activity.observe(busy: false, at: at(3))
        #expect(activity.state == .running(since: at(0)))
    }

    @Test("Typed, seen busy, then two idle readings is a stop, measured to the first idle one")
    func typedBusyIdle() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: true, at: at(1))
        activity.observe(busy: true, at: at(120))
        activity.observe(busy: false, at: at(134))
        // One idle reading is a prompt hook or a watcher restarting, not a stop.
        #expect(activity.state == .running(since: at(0)))
        activity.observe(busy: false, at: at(135))
        #expect(activity.state == .stopped(after: .seconds(134)))
    }

    @Test("An idle reading between two busy ones is forgotten")
    func debounceResets() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: true, at: at(1))
        activity.observe(busy: false, at: at(2))
        activity.observe(busy: true, at: at(3))
        activity.observe(busy: false, at: at(4))
        #expect(activity.state.isRunning)
        activity.observe(busy: false, at: at(5))
        #expect(activity.state == .stopped(after: .seconds(4)))
    }

    @Test("A command never seen running is believed stopped after the grace, with no length")
    func tooQuickToSee() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: false, at: at(7))
        #expect(activity.state.isRunning)
        activity.observe(busy: false, at: at(8))
        #expect(activity.state == .stopped(after: nil))
    }

    @Test("A pane nobody typed into reads as idle, whatever its idle readings")
    func idleBeforeTypingIsIgnored() {
        var activity = RunScriptActivity()
        activity.observe(busy: false, at: at(1))
        activity.observe(busy: false, at: at(2))
        #expect(activity.state == .idle)
    }

    @Test("A single busy reading in an untyped pane is a prompt hook, two are a job")
    func untypedBusyNeedsTwo() {
        var activity = RunScriptActivity()
        activity.observe(busy: true, at: at(1))
        #expect(activity.state == .idle)
        activity.observe(busy: false, at: at(2))
        activity.observe(busy: true, at: at(3))
        #expect(activity.state == .idle)
        activity.observe(busy: true, at: at(4))
        #expect(activity.state == .running(since: at(3)))
    }

    @Test("Up and Return after a stop runs again, and the strip goes")
    func runningAgainByHand() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: true, at: at(1))
        activity.observe(busy: false, at: at(2))
        activity.observe(busy: false, at: at(3))
        #expect(activity.state == .stopped(after: .seconds(2)))
        activity.observe(busy: true, at: at(10))
        #expect(activity.state == .stopped(after: .seconds(2)))
        activity.observe(busy: true, at: at(11))
        #expect(activity.state == .running(since: at(10)))
    }

    @Test("Typing into a command that is running is an answer, not a restart")
    func typedIntoRunning() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: true, at: at(1))
        activity.typed(at: at(50))
        #expect(activity.state == .running(since: at(0)))
    }

    @Test("Run Again after a stop starts the clock again")
    func typedAfterStop() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: true, at: at(1))
        activity.observe(busy: false, at: at(2))
        activity.observe(busy: false, at: at(3))
        activity.typed(at: at(20))
        #expect(activity.state == .running(since: at(20)))
    }

    @Test("A deliberate reading of a busy terminal is believed at once, an idle one is not")
    func adopting() {
        var restored = RunScriptActivity()
        restored.adopt(busy: true, at: at(1))
        #expect(restored.state == .running(since: at(1)))

        var fresh = RunScriptActivity()
        fresh.adopt(busy: false, at: at(1))
        #expect(fresh.state == .idle)
    }

    @Test("Dismissing the stopped strip returns the pane to saying nothing")
    func dismissing() {
        var activity = RunScriptActivity()
        activity.typed(at: at(0))
        activity.observe(busy: true, at: at(1))
        activity.dismiss()
        #expect(activity.state.isRunning)
        activity.observe(busy: false, at: at(2))
        activity.observe(busy: false, at: at(3))
        activity.dismiss()
        #expect(activity.state == .idle)
    }
}
