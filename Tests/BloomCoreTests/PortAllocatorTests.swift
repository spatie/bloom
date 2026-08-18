import Testing
import Foundation
@testable import BloomCore

/// Serialized on purpose.
///
/// `PortAllocator` decides whether a port is free by actually binding a socket, so two of these
/// running at the same time genuinely invalidate each other: one test binds a port inside the
/// range the other is probing and the other sees a block it thought was free disappear. They used
/// to live in two different suites and were given two different port ranges to keep them apart,
/// which is a workaround rather than a fix. Serializing the suite is the fix, and the ranges stay
/// distinct only as defence against unrelated processes on the machine.
///
/// Nothing here asserts that a block is *still* free after `allocate` returned it. That is an
/// assertion about the whole machine rather than about this code, and it flaked. Every assertion
/// below is driven by an explicit `taken` set instead, which is deterministic.
@Suite("PortAllocator", .serialized)
struct PortAllocatorTests {
    @Test("hands out a block at or after the requested start")
    func allocatesFromTheStart() throws {
        let first = try PortAllocator.allocate(taken: [], start: 41_000)
        #expect(first >= 41_000)
        #expect(first.isMultiple(of: PortAllocator.blockSize))
    }

    @Test("never hands the same block out twice")
    func doesNotRepeatABlock() throws {
        let base = 42_000
        let first = try PortAllocator.allocate(taken: [], start: base)
        let second = try PortAllocator.allocate(taken: [first], start: base)
        // Deliberately relative, not `first + 10`: another process on this machine may hold a
        // port in the next block, and that is not this test's business.
        #expect(second > first)
        #expect((second - first).isMultiple(of: PortAllocator.blockSize))
    }

    @Test("one taken port disqualifies the whole block it sits in")
    func oneTakenPortSkipsTheBlock() throws {
        let base = 41_000
        let first = try PortAllocator.allocate(taken: [], start: base)
        let second = try PortAllocator.allocate(taken: [first + 3], start: base)
        // The point is that one taken port costs the whole block, not just that one port.
        #expect(second >= first + PortAllocator.blockSize)
        #expect((second - first).isMultiple(of: PortAllocator.blockSize))
    }

    @Test("fails loudly when the range cannot hold a block")
    func refusesARangeTooSmall() {
        #expect(throws: PortAllocatorError.self) {
            _ = try PortAllocator.allocate(taken: [], start: 3_100, limit: 3_105)
        }
    }

    @Test("fails loudly rather than returning a port that is taken")
    func refusesWhenEveryPortIsTaken() {
        // The old code answered `start` here even though `start` was explicitly taken, which sent
        // a run script straight into someone else's server.
        #expect(throws: PortAllocatorError.self) {
            _ = try PortAllocator.allocate(taken: Set(3_100...3_200), start: 3_100, limit: 3_150)
        }
    }
}
