import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Synchronization
import Testing
@testable import BloomCore

@Suite("Server lock wait", .tags(.persistence), .scratchDirectory)
struct ServerLockWaitTests {
    private let ownership = "A Bloom server already owns this data directory."

    @Test func aLockReleasedWithinTheWindowIsAcquired() async throws {
        let directory = try lockDirectory()
        let holder = try hold(directory)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(200))
            close(holder)
        }
        // The window is far longer than the release so a stalled CI executor cannot turn this
        // into a refusal. The start returns as soon as the holder lets go.
        let lock = try await ServerLock(directory: directory, wait: ServerLockWait(window: .seconds(120), interval: .milliseconds(10)))
        lock.release()
        await release.value
    }

    @Test func aLockHeldBeyondTheWindowIsRefusedAsOwnership() async throws {
        let directory = try lockDirectory()
        let holder = try hold(directory)
        defer { close(holder) }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let lock = try await ServerLock(directory: directory, wait: ServerLockWait(window: .milliseconds(300), interval: .milliseconds(20)))
            lock.release()
            Issue.record("Expected a held lock to be refused")
        } catch let failure as ServerFailure {
            #expect(failure.message == ownership)
        }
        #expect(started.duration(to: clock.now) >= .milliseconds(300))
    }

    @Test func onlyTheOwnershipErrnoWaits() async {
        let clock = SteppedClock()
        let attempts = Mutex(0)
        let refused = await ServerLockWait().acquire(on: clock) {
            attempts.withLock { $0 += 1 }
            return ENOLCK
        }
        #expect(refused == ENOLCK)
        #expect(attempts.withLock { $0 } == 1)
        #expect(clock.now == SteppedClock.Instant(offset: .zero))
    }

    @Test func aBriefHolderIsWaitedOutOnTheSameClock() async {
        let clock = SteppedClock()
        let attempts = Mutex(0)
        let refused = await ServerLockWait().acquire(on: clock) {
            attempts.withLock { $0 += 1 }
            return attempts.withLock { $0 } < 4 ? EWOULDBLOCK : nil
        }
        #expect(refused == nil)
        #expect(attempts.withLock { $0 } == 4)
        #expect(clock.now == SteppedClock.Instant(offset: .milliseconds(150)))
    }

    @Test func aHeldLockIsRefusedAtTheWindowAndNoLater() async {
        let clock = SteppedClock()
        let attempts = Mutex(0)
        let wait = ServerLockWait(window: .milliseconds(120), interval: .milliseconds(50))
        let refused = await wait.acquire(on: clock) {
            attempts.withLock { $0 += 1 }
            return EAGAIN
        }
        #expect(refused == EAGAIN)
        // Attempts at 0, 50, 100 and a last one cut short to land on 120.
        #expect(attempts.withLock { $0 } == 4)
        #expect(clock.now == SteppedClock.Instant(offset: .milliseconds(120)))
    }

    @Test func stepDecisions() {
        let wait = ServerLockWait(window: .seconds(3), interval: .milliseconds(50))
        #expect(wait.step(code: nil, elapsed: .seconds(10)) == .acquired)
        #expect(wait.step(code: EWOULDBLOCK, elapsed: .zero) == .wait(.milliseconds(50)))
        #expect(wait.step(code: EWOULDBLOCK, elapsed: .milliseconds(2_980)) == .wait(.milliseconds(20)))
        #expect(wait.step(code: EWOULDBLOCK, elapsed: .seconds(3)) == .refuse(EWOULDBLOCK))
        #expect(wait.step(code: ENOLCK, elapsed: .zero) == .refuse(ENOLCK))
    }

    private func lockDirectory() throws -> String {
        let directory = TestScratch.unique("server-lock")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// A second, independent descriptor holding the lock, as another process would.
    private func hold(_ directory: String) throws -> Int32 {
        let path = (directory as NSString).appendingPathComponent("server.lock")
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ServerFailure("The test could not take its own lock.")
        }
        return descriptor
    }
}

/// A clock whose sleeps pass at once and move `now` to the deadline, so a three second window
/// is walked in no real time and the time it would have taken is still observable.
private final class SteppedClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let current = Mutex(Instant(offset: .zero))
    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        current.withLock { $0 = max($0, deadline) }
    }
}
