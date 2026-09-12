import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite struct CodexFamilyStopTests {
    @Test func earlyTurnAnnouncementsBecomeOwnedOnlyAfterRegistration() {
        var children = CodexSubagents()
        _ = children.receive(.turnStarted(CodexTurn(id: "turn", threadID: "child", status: .inProgress)), parentThreadID: "parent")
        #expect(children.liveTurns.isEmpty)
        _ = children.receive(.itemCompleted(CodexItemEvent(item: .subAgentActivity(CodexSubAgentActivity(
            id: "spawn", agentPath: "/root/worker", agentThreadID: "child", kind: "started"
        )), threadID: "parent", turnID: "parent-turn")), parentThreadID: "parent")
        #expect(children.liveTurns == ["child": "turn"])
        let stale = children.receive(.turnCompleted(CodexTurn(id: "old-turn", threadID: "child", status: .completed)), parentThreadID: "parent")
        #expect(stale.isEmpty)
        #expect(children.liveTurns == ["child": "turn"])
        _ = children.receive(.turnCompleted(CodexTurn(id: "turn", threadID: "child", status: .completed)), parentThreadID: "parent")
        #expect(children.liveTurns.isEmpty)
    }

    @Test func eachChildGetsABoundedDeadlineAndConcurrencyIsLimited() async {
        let state = Mutex((active: 0, peak: 0, completed: 0))
        let children = Dictionary(uniqueKeysWithValues: (0..<20).map { ("child-\($0)", "turn-\($0)") })
        await CodexFamilyStop.interrupt(children, budget: .seconds(60), concurrency: 3) { _, _, timeout in
            #expect(timeout > .zero && timeout <= .seconds(3))
            state.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            await Task.yield()
            state.withLock { $0.active -= 1; $0.completed += 1 }
        }
        let result = state.withLock { $0 }
        #expect(result.peak <= 3)
        #expect(result.completed == 20)
    }
    @Test func anExpiredBudgetNeverStartsChildRequests() async {
        let calls = Mutex(0)
        await CodexFamilyStop.interrupt(["child": "turn"], budget: .zero) { _, _, _ in
            calls.withLock { $0 += 1 }
        }
        #expect(calls.withLock { $0 } == 0)
    }

}
