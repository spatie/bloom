import Foundation
import Testing
@testable import BloomCore

@Suite("Ordering workspace target changes")
@MainActor
struct BaseBranchChangeQueueTests {
    private actor Gate {
        private var arrived = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?

        func pause() async {
            arrived = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { held = $0 }
        }

        func waitForArrival() async {
            guard !arrived else { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func open() {
            held?.resume()
            held = nil
        }
    }

    @Test("An older fetch completing after a newer target cannot restore its stale answer")
    func supersededFetch() async {
        let queue = BaseBranchChangeQueue()
        let workspaceID = WorkspaceID("sea")
        let gate = Gate()
        var recorded: [String] = []
        let first = queue.begin(for: workspaceID)
        let older = Task {
            await gate.pause()
            await queue.write(first) { recorded.append("develop") }
        }
        await gate.waitForArrival()
        let second = queue.begin(for: workspaceID)
        await queue.write(second) { recorded.append("release") }
        await gate.open()
        await older.value

        #expect(recorded == ["release"])
    }

    @Test("A newer poll with no target still invalidates an older fetch")
    func supersededWithoutReplacement() async {
        let queue = BaseBranchChangeQueue()
        let request = queue.begin(for: WorkspaceID("sea"))
        let gate = Gate()
        var pollIsCurrent = true
        var recorded: [String] = []
        let older = Task {
            await gate.pause()
            await queue.write(request, isCurrent: { pollIsCurrent }) { recorded.append("develop") }
        }
        await gate.waitForArrival()
        pollIsCurrent = false
        await gate.open()
        await older.value

        #expect(recorded.isEmpty)
    }

    @Test("A target being written finishes before the next target can write either destination")
    func serialisesSuspendingWrites() async {
        let queue = BaseBranchChangeQueue()
        let workspaceID = WorkspaceID("sea")
        let gate = Gate()
        var recorded: [String] = []
        let first = queue.begin(for: workspaceID)
        let older = Task {
            await queue.write(first) {
                recorded.append("git develop")
                await gate.pause()
                recorded.append("store develop")
            }
        }
        await gate.waitForArrival()
        let second = queue.begin(for: workspaceID)
        let newer = Task {
            await queue.write(second) {
                recorded.append("git release")
                recorded.append("store release")
            }
        }
        await gate.open()
        await older.value
        await newer.value

        #expect(recorded == ["git develop", "store develop", "git release", "store release"])
    }

    @Test("Another workspace's change cannot invalidate this workspace's target")
    func independentWorkspaces() async {
        let queue = BaseBranchChangeQueue()
        let first = queue.begin(for: WorkspaceID("sea"))
        let second = queue.begin(for: WorkspaceID("ocean"))
        var recorded: [String] = []
        await queue.write(second) { recorded.append("ocean") }
        await queue.write(first) { recorded.append("sea") }
        #expect(recorded == ["ocean", "sea"])
    }
}
