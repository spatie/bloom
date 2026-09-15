import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory)
struct SessionRunnerFactoryTests {
    @Test("The shared runtime factory selects Grok's ACP runner without starting a process")
    func grokUsesItsOwnRunner() async throws {
        let store = try makeTestStore("grok-factory")
        let session = Session(workspaceID: nil, model: "grok-4.6", agentKind: .grok)
        let runner = SessionRunnerFactory.make(session: session, workspacePath: "/tmp/grok-factory", store: store)
        let grok = try #require(runner as? GrokRunner)
        #expect(grok.agentKind == .grok)
        #expect(grok.sessionID == session.id)
        #expect(grok.workspacePath == "/tmp/grok-factory")
        let alive = await grok.isProcessAlive
        #expect(!alive)
    }
}
