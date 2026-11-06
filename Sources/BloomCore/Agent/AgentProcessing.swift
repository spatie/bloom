import Foundation

/// What `AgentRunner` needs from a subprocess. `StreamingProcess` is the only production
/// implementation. It is a protocol so tests can drive the runner without launching the real
/// `claude` binary, which would need a network, an account, and money.
public protocol AgentProcessing: Sendable {
    var lines: AsyncThrowingStream<String, Error> { get }
    var errorLines: AsyncStream<String> { get }
    var isRunning: Bool { get }
    var exitStatus: Int32 { get async }

    func writeLine(_ text: String)
    func closeStdin()
    func terminate()
    func kill()
}

extension StreamingProcess: AgentProcessing {}
