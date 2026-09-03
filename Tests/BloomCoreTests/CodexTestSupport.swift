import Testing
import Foundation
@testable import BloomCore

// MARK: - A server that never was

/// Stands in for `codex app-server`. It reads the frames Bloom writes, answers requests from a
/// table the test fills, and can push notifications and server-to-client requests of its own.
///
/// The canned answers are the ones a real server sent, copied out of the recordings, so the client
/// is exercised against the shapes it will actually meet rather than against ones invented to suit
/// it.
final class ScriptedCodexProcess: AgentProcessing, @unchecked Sendable {
    let launch: AgentLaunch

    private let lock = NSLock()
    private var written: [String] = []
    private var running = true
    private var replies: [String: JSONValue] = [:]
    private var failures: [String: (code: Int, message: String)] = [:]
    private var ignored: Set<String> = []

    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation

    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>

    init(launch: AgentLaunch) {
        self.launch = launch

        var out: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream(bufferingPolicy: .unbounded) { out = $0 }
        stdoutContinuation = out

        var err: AsyncStream<String>.Continuation!
        errorLines = AsyncStream(bufferingPolicy: .unbounded) { err = $0 }
        stderrContinuation = err
    }

    // MARK: Scripting

    func reply(to method: String, with result: JSONValue) {
        lock.lock(); replies[method] = result; lock.unlock()
    }

    func fail(_ method: String, code: Int, message: String) {
        lock.lock(); failures[method] = (code, message); lock.unlock()
    }

    /// A method the server simply never answers, which is what a hung request looks like.
    func ignore(_ method: String) {
        lock.lock(); ignored.insert(method); lock.unlock()
    }

    func emit(_ line: String) {
        stdoutContinuation.yield(line)
    }

    func emitError(_ line: String) {
        stderrContinuation.yield(line)
    }

    func endOutput() {
        lock.lock(); running = false; lock.unlock()
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }

    var stdin: [String] {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    /// The methods Bloom sent, in order, requests and notifications alike.
    var sentMethods: [String] {
        stdin.compactMap { JSONValue.parse($0)?["method"]?.stringValue }
    }

    func sentFrame(matching predicate: (JSONValue) -> Bool) -> JSONValue? {
        stdin.compactMap(JSONValue.parse).first(where: predicate)
    }

    // MARK: AgentProcessing

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var exitStatus: Int32 { get async { 0 } }

    func writeLine(_ text: String) {
        lock.lock()
        written.append(text)
        let table = replies
        let refusals = failures
        let silent = ignored
        lock.unlock()

        guard let json = JSONValue.parse(text),
              let method = json["method"]?.stringValue,
              let id = json["id"],
              !silent.contains(method)
        else { return }

        if let refusal = refusals[method] {
            let error = JSONValue.object([
                "code": .integer(refusal.code),
                "message": .string(refusal.message),
            ])
            emit("{\"id\":\(id.compactJSON),\"error\":\(error.compactJSON)}")
            return
        }
        // Deliberately without a `jsonrpc` member, which is what the real server does.
        let result = table[method] ?? .object([:])
        emit("{\"id\":\(id.compactJSON),\"result\":\(result.compactJSON)}")
    }

    func closeStdin() {}

    func terminate() {
        endOutput()
    }

    func kill() {
        endOutput()
    }
}

/// Holds the script, because the process itself does not exist until `start()` launches it and a
/// test has to be able to say what the server will answer before that.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var made: ScriptedCodexProcess?
    /// Every process this box has handed out, in order. A reconnect is a second one, and asking
    /// for `process` alone cannot tell "launched once" from "launched again with other arguments".
    private var started: [ScriptedCodexProcess] = []
    private var replies: [String: JSONValue] = [:]
    private var failures: [String: (code: Int, message: String)] = [:]
    private var ignored: [String] = []

    func ignore(_ method: String) {
        lock.lock(); ignored.append(method); let live = made; lock.unlock()
        live?.ignore(method)
    }

    func reply(to method: String, with result: JSONValue) {
        lock.lock(); replies[method] = result; let live = made; lock.unlock()
        live?.reply(to: method, with: result)
    }

    func fail(_ method: String, code: Int, message: String) {
        lock.lock(); failures[method] = (code, message); let live = made; lock.unlock()
        live?.fail(method, code: code, message: message)
    }

    var factory: @Sendable (AgentLaunch) -> any AgentProcessing {
        { launch in
            let process = ScriptedCodexProcess(launch: launch)
            self.lock.lock()
            self.made = process
            self.started.append(process)
            let replies = self.replies
            let failures = self.failures
            let ignored = self.ignored
            self.lock.unlock()

            for (method, result) in replies { process.reply(to: method, with: result) }
            for (method, refusal) in failures {
                process.fail(method, code: refusal.code, message: refusal.message)
            }
            for method in ignored { process.ignore(method) }
            return process
        }
    }

    var process: ScriptedCodexProcess {
        lock.lock(); defer { lock.unlock() }
        return made!
    }

    var processes: [ScriptedCodexProcess] {
        lock.lock(); defer { lock.unlock() }
        return started
    }
}
