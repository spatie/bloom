import Foundation

/// On Linux, Foundation tracks child exit through a descriptor inherited by tmux's daemon.
/// Running tmux in the foreground avoids that daemonisation path. The Bloom server owns it,
/// independently of any connected Mac or attached terminal client.
actor ServerTerminalService {
    private var processes: [String: StreamingProcess] = [:]
    private var pumps: [String: Task<Void, Never>] = [:]
    private var starts: [String: Task<Void, Error>] = [:]

    func start(command: TmuxCommand, key: String, cwd: String) async throws {
        #if os(Linux)
        if let task = starts[key] { return try await task.value }
        if processes[key]?.isRunning == true { return }
        let task = Task { try await self.launch(command: command, key: key, cwd: cwd) }
        starts[key] = task
        defer { starts.removeValue(forKey: key) }
        try await task.value
        #endif
    }

    private func launch(command: TmuxCommand, key: String, cwd: String) async throws {
        let process = StreamingProcess(executable: command.executable, arguments: command.arguments(["-D"]), cwd: cwd)
        processes[key] = process
        let lines = process.lines
        pumps[key] = Task { do { for try await _ in lines {} } catch { /* The readiness probe reports a failed terminal launch. */ } }
        for _ in 0..<30 {
            let probe = try await Shell.run(command.executable, command.arguments(["show-options", "-g", "exit-empty"]), cwd: cwd)
            if probe.ok { return }
            guard process.isRunning else { throw ServerFailure("The server terminal could not start.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw ServerFailure("The server terminal did not become ready.")
    }

    func shutdown() {
        for process in processes.values { process.terminate() }
        for pump in pumps.values { pump.cancel() }
        processes.removeAll(); pumps.removeAll()
    }

    deinit {
        for process in processes.values { process.terminate() }
        for pump in pumps.values { pump.cancel() }
    }
}
