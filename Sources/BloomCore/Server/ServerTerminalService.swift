import Foundation

/// On Linux, Foundation tracks child exit through a descriptor inherited by tmux's daemon.
/// Running tmux in the foreground avoids that daemonisation path. The Bloom server owns it,
/// independently of any connected Mac or attached terminal client.
actor ServerTerminalService {
    private var processes: [String: StreamingProcess] = [:]
    private var pumps: [String: Task<Void, Never>] = [:]
    private var starts: [String: Task<Void, Error>] = [:]
    private var commands: [String: TmuxCommand] = [:]
    private var isClosed = false
    private var shutdownTask: Task<Void, Never>?
    private let ownsDaemon: Bool
    private let makeProcess: @Sendable (TmuxCommand, String) -> StreamingProcess
    private let run: @Sendable (TmuxCommand, [String], String) async throws -> ShellResult

    init(ownsDaemon: Bool? = nil,
         makeProcess: (@Sendable (TmuxCommand, String) -> StreamingProcess)? = nil,
         run: (@Sendable (TmuxCommand, [String], String) async throws -> ShellResult)? = nil) {
        #if os(Linux)
        self.ownsDaemon = ownsDaemon ?? true
        #else
        self.ownsDaemon = ownsDaemon ?? false
        #endif
        self.makeProcess = makeProcess ?? { command, cwd in
            StreamingProcess(executable: command.executable, arguments: command.arguments(["-D"]), cwd: cwd)
        }
        self.run = run ?? { command, arguments, cwd in
            try await Shell.run(command.executable, command.arguments(arguments), cwd: cwd, timeout: .seconds(5))
        }
    }

    func start(command: TmuxCommand, key: String, cwd: String) async throws {
        guard !isClosed else { throw ServerFailure("The server is shutting down.") }
        commands[key] = command
        guard ownsDaemon else { return }
        if let task = starts[key] { return try await task.value }
        if processes[key]?.isRunning == true { return }
        let task = Task { try await self.launch(command: command, key: key, cwd: cwd) }
        starts[key] = task
        defer { starts.removeValue(forKey: key) }
        try await task.value
    }

    private func launch(command: TmuxCommand, key: String, cwd: String) async throws {
        try Task.checkCancellation()
        guard !isClosed else { throw ServerFailure("The server is shutting down.") }
        let process = makeProcess(command, cwd)
        processes[key] = process
        let lines = process.lines
        let pump = Task { do { for try await _ in lines {} } catch { /* The readiness probe reports a failed terminal launch. */ } }
        pumps[key] = pump
        do {
            for _ in 0..<30 {
                let probe = try await run(command, ["show-options", "-g", "exit-empty"], cwd)
                try Task.checkCancellation()
                guard !isClosed else { throw ServerFailure("The server is shutting down.") }
                if probe.ok { return }
                guard process.isRunning else { throw ServerFailure("The server terminal could not start.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ServerFailure("The server terminal did not become ready.")
        } catch {
            await ServerTerminalProcessLifetime.stop(process).value
            pump.cancel()
            await pump.value
            processes[key] = nil; pumps[key] = nil
            throw error
        }
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
        if let shutdownTask { await shutdownTask.value; return }
        isClosed = true
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
    }

    private func finishShutdown() async {
        let pending = Array(starts.values)
        for start in pending { start.cancel() }
        for start in pending { _ = try? await start.value }
        // Control commands need the stable server directory, not a worktree that may already
        // have been archived. Start workers have settled before this final ownership cleanup.
        for command in commands.values {
            let directory = URL(fileURLWithPath: command.configPath).deletingLastPathComponent().path
            _ = try? await run(command, ["kill-server"], directory)
        }
        let endings = processes.values.map(ServerTerminalProcessLifetime.stop)
        for ending in endings { await ending.value }
        for pump in pumps.values { pump.cancel() }
        for pump in pumps.values { await pump.value }
        processes.removeAll(); pumps.removeAll(); commands.removeAll()
    }

    deinit {
        for process in processes.values { process.terminate() }
        for pump in pumps.values { pump.cancel() }
    }
}
