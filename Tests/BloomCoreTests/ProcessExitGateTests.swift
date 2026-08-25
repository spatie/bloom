import Foundation
import Testing
@testable import BloomCore

/// The hang this type exists to stop.
///
/// `Shell.run` and `Git.runRaw` installed `terminationHandler` after `process.run()`, so a child
/// that exited inside that window never called it and the awaiting task never resumed. Most git
/// calls pass no timeout, so nothing broke the hang afterwards.
@Suite("Waiting for a process that may already have exited")
struct ProcessExitGateTests {
    @Test("a signal that arrives before anybody waits is remembered")
    func signalBeforeWait() async {
        let gate = ProcessExitGate()
        gate.signal()
        // Would hang forever if the exit were not remembered, which is the bug.
        await gate.wait()
    }

    @Test("a waiter parked first is resumed by the signal")
    func waitBeforeSignal() async {
        let gate = ProcessExitGate()
        async let waited: Void = gate.wait()
        // Give the waiter a chance to park before the signal lands.
        try? await Task.sleep(for: .milliseconds(20))
        gate.signal()
        await waited
    }

    @Test("signalling twice does not resume a continuation twice")
    func signalIsIdempotent() async {
        let gate = ProcessExitGate()
        async let waited: Void = gate.wait()
        try? await Task.sleep(for: .milliseconds(20))
        gate.signal()
        // A second resume of the same continuation traps, so reaching the end is the assertion.
        gate.signal()
        await waited
        gate.signal()
    }

    @Test("a real short lived process is waited on rather than hung on")
    func realProcessThatExitsImmediately() async throws {
        // `true` exits about as fast as anything can, which is the case that used to lose the
        // race with the line installing the handler.
        for _ in 0..<25 {
            let result = try await Shell.run("/usr/bin/true", [])
            #expect(result.ok)
        }
    }
}
