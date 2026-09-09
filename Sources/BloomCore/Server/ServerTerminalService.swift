import Foundation

/// On Linux, Foundation tracks child exit through a descriptor inherited by tmux's daemon.
/// Running tmux in the foreground avoids that daemonisation path. The Bloom server owns it,
/// independently of any connected Mac or attached terminal client.
actor ServerTerminalService {
    private var processes: [String: StreamingProcess] = [:]
    private var pumps: [String: Task<Void, Never>] = [:]
    private var starts: [String: Task<Void, Error>] = [:]
    private var commands: [String: (TmuxCommand, String)] = [:]
    private var isClosed = false

    func start(command: TmuxCommand, key: String, cwd: String) async throws {
        guard !isClosed else { throw ServerFailure("The server is shutting down.") }
        commands[key] = (command, cwd)
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

    func close(workspaceID: WorkspaceID, store: Store, cwd: String) async throws {
        guard let executable = Shell.which("tmux") else { return }
        let command = TmuxCommand(executable: executable, socketName: TmuxSessions.socketName(databasePath: store.path),
            configPath: URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("tmux.conf").path)
        let listed = try await Shell.run(executable, command.arguments(["list-sessions", "-F", "#{session_name}"]), cwd: cwd)
        guard listed.ok else { return }
        let owner = TmuxSessions.workspaceID(ofSessionName: TmuxSessions.sessionName(workspaceID: workspaceID, paneID: "main"))
        for name in listed.stdout.split(separator: "\n").map(String.init) where TmuxSessions.workspaceID(ofSessionName: name) == owner {
            _ = try await Shell.run(executable, command.arguments(["kill-session", "-t", "=" + name]), cwd: cwd)
        }
    }

    func shutdown() async {
        isClosed = true
        for start in starts.values { start.cancel() }
        // A tmux server owns PTYs whose shells use separate process groups. Ask tmux to close
        // those sessions before terminating its process, so a service stop leaves no shell behind.
        for (command, cwd) in commands.values {
            _ = try? await Shell.run(command.executable, command.arguments(["kill-server"]), cwd: cwd)
        }
        for process in processes.values { process.terminate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while processes.values.contains(where: \.isRunning), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        for process in processes.values where process.isRunning { process.kill() }
        for pump in pumps.values { pump.cancel() }
        processes.removeAll(); pumps.removeAll(); commands.removeAll()
    }

    deinit {
        for process in processes.values { process.terminate() }
        for pump in pumps.values { pump.cancel() }
    }
}
