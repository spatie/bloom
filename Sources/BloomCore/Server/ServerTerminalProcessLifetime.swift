import Foundation

/// A cancelled stream iterator does not reap its child. Both terminal owners keep this task
/// until exit, with escalation independent of the caller's cancellation state.
enum ServerTerminalProcessLifetime {
    static func stop(_ process: StreamingProcess) -> Task<Void, Never> {
        process.terminate()
        return Task.detached {
            let escalation = Task.detached {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                process.kill()
            }
            defer { escalation.cancel() }
            _ = await process.exitStatus
        }
    }
}
