import Testing
@testable import BloomCore

@Suite struct CodexSendRecoveryTests {
    @Test func onlyADefinitiveInactiveTurnRejectionAllowsFallback() {
        #expect(CodexSendRecovery.permitsNewTurn(after: CodexRPCError(code: -32602, message: "No active turn")))
        #expect(!CodexSendRecovery.permitsNewTurn(after: CodexRPCError(code: -32603, message: "internal failure")))
        #expect(!CodexSendRecovery.permitsNewTurn(after: CodexClientError.timedOut(method: "turn/steer", seconds: 120)))
        #expect(!CodexSendRecovery.permitsNewTurn(after: CodexClientError.connectionClosed("EOF")))
    }
}
