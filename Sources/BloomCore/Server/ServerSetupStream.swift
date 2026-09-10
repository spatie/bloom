import Foundation
import Synchronization

/// Both channels are consumed while the helper runs. Non-JSON diagnostics are useful output,
/// rather than a reason to silently discard the package manager's explanation of a failure.
enum ServerSetupStream {
    static func run(_ process: StreamingProcess, input: String, timeout: Duration = .seconds(900),
                    killDelay: Duration = .seconds(2), acceptsFailureEvent: Bool = false,
                    requiresCompletion: Bool = true, commandLabel: String = "ssh", step: String? = nil,
                    progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent {
        let lifetime = ServerSetupProcessLifetime(process: process, killDelay: killDelay)
        let output = ServerSetupStreamOutput(step: step, decodesEvents: requiresCompletion, progress: progress)
        let deadline = Task {
            do { try await Task.sleep(for: timeout); lifetime.stop(timedOut: true) } catch { /* Normal completion cancels the deadline. */ }
        }
        defer { deadline.cancel(); lifetime.finish() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do { try lifetime.start() } catch {
                try Task.checkCancellation()
                if lifetime.didTimeOut { throw ServerSetupFailure(code: .timedOut) }
                throw ServerSetupFailure.classify(status: (error as? ShellError)?.status ?? -1,
                    stderr: (error as? ShellError)?.stderr ?? String(describing: error), command: commandLabel)
            }
            async let errors: Void = {
                for await line in process.errorLines { await output.stderr(line) }
            }()
            process.write(input)
            process.closeStdin()
            var streamError: Error?
            do {
                for try await line in process.lines { await output.stdout(line) }
            } catch { streamError = error; lifetime.stop(timedOut: false) }
            let status = await process.exitStatus
            await errors
            try Task.checkCancellation()
            let result = await output.result
            if lifetime.didTimeOut {
                throw ServerSetupFailure.installation(code: "timed_out", details: result.tail, command: commandLabel, exitStatus: Int(status))
            }
            if let failure = result.failure {
                if acceptsFailureEvent { return failure }
                throw ServerSetupFailure.installation(code: failure.code ?? "installation_failed", message: failure.message,
                    recovery: failure.recovery, details: failure.details ?? result.tail,
                    command: failure.command ?? commandLabel, exitStatus: failure.exitStatus ?? Int(status))
            }
            if status == 0, let completed = result.completed { return completed }
            if status == 0, !requiresCompletion { return ServerInstallEvent(event: "complete", step: step) }
            let details = result.tail.isEmpty ? streamError?.localizedDescription ?? "The installer exited without a completion event." : result.tail
            throw ServerSetupFailure.classify(status: status, stderr: details, command: commandLabel)
        } onCancel: { lifetime.stop(timedOut: false) }
    }
}

private final class ServerSetupProcessLifetime: Sendable {
    private struct State {
        var stopped = false
        var timedOut = false
        var killer: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let process: StreamingProcess
    private let killDelay: Duration
    init(process: StreamingProcess, killDelay: Duration) { self.process = process; self.killDelay = killDelay }
    var didTimeOut: Bool { state.withLock { $0.timedOut } }
    func start() throws {
        try state.withLock { state in
            guard !state.stopped else { throw CancellationError() }
            try process.start()
        }
    }
    func stop(timedOut: Bool) {
        state.withLock { state in
            guard !state.stopped else { return }
            state.stopped = true; state.timedOut = timedOut
            process.terminate()
            state.killer = Task {
                do { try await Task.sleep(for: killDelay); process.kill() } catch { /* Exited before escalation. */ }
            }
        }
    }
    func finish() { state.withLock { $0.killer?.cancel(); $0.killer = nil } }
}

private actor ServerSetupStreamOutput {
    struct Result: Sendable {
        var completed: ServerInstallEvent?
        var failure: ServerInstallEvent?
        var tail = ""
    }
    private(set) var result = Result()
    private var outputSanitiser = ServerSetupOutputSanitiser()
    private var errorSanitiser = ServerSetupOutputSanitiser()
    private var step: String?
    private let progress: @Sendable (ServerInstallEvent) async -> Void
    private let decodesEvents: Bool
    init(step: String?, decodesEvents: Bool, progress: @escaping @Sendable (ServerInstallEvent) async -> Void) {
        self.step = step; self.decodesEvents = decodesEvents; self.progress = progress
    }

    func stdout(_ line: String) async {
        guard decodesEvents, line.utf8.count <= 65_536,
              var event = try? JSONDecoder().decode(ServerInstallEvent.self, from: Data(line.utf8)) else {
            if let text = outputSanitiser.line(line) { await emit(text) }
            return
        }
        if let value = event.step, value.utf8.count <= 80 { step = ServerSetupDiagnostics.optional(value, limit: 80) }
        event.step = step
        event.message = event.message.flatMap { outputSanitiser.line($0) }
        event.recovery = ServerSetupDiagnostics.optional(event.recovery)
        event.details = ServerSetupDiagnostics.optional(event.details)
        event.command = ServerSetupDiagnostics.optional(event.command, limit: 256)
        event.code = ServerSetupDiagnostics.optional(event.code, limit: 100)
        if let text = event.message { retain(text) }
        if let details = event.details { retain(details) }
        if event.event == "complete" { result.completed = event }
        if event.event == "error" { result.failure = event }
        await progress(event)
    }

    func stderr(_ line: String) async {
        if let text = errorSanitiser.line(line) { await emit(text) }
    }

    private func emit(_ text: String) async {
        retain(text)
        await progress(ServerInstallEvent(event: "output", step: step, message: text))
    }

    private func retain(_ text: String) {
        let value = result.tail + (result.tail.isEmpty ? "" : "\n") + text
        result.tail = String(decoding: value.utf8.suffix(ServerSetupDiagnostics.detailLimit), as: UTF8.self)
    }
}
