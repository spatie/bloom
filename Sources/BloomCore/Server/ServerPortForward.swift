import Foundation

/// A loopback-only SSH tunnel keeps preview servers private. Its lifetime belongs to the Mac
/// connection, while the process serving the page belongs to the remote terminal.
public actor ServerPortForward {
    public let localPort: Int
    private let process: StreamingProcess
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var ready = false
    private var failure = ""

    private init(port: Int, launch: AgentLaunch) {
        localPort = port
        process = StreamingProcess(executable: launch.executable, arguments: launch.arguments,
            cwd: launch.cwd, environment: launch.environment, mergeStderr: false)
    }

    public static func connect(endpoint: ServerEndpoint, remotePort: Int) async throws -> ServerPortForward {
        var lastError = "Could not open a preview tunnel."
        for _ in 0..<4 {
            let port = Int.random(in: 49_152...65_535)
            let forward = try ServerPortForward(port: port, launch: endpoint.forwardLaunch(remotePort: remotePort, localPort: port))
            do { try await forward.start(); return forward } catch { lastError = error.localizedDescription; await forward.close() }
        }
        throw ServerFailure(lastError)
    }

    private func start() async throws {
        let errors = process.errorLines
        let lines = process.lines
        outputTask = Task { do { for try await _ in lines {} } catch { /* SSH stderr is collected separately and reported by start(). */ } }
        errorTask = Task { [weak self] in
            for await line in errors { await self?.receive(line) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !ready, process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ready, process.isRunning else { throw ServerFailure(failure.isEmpty ? "The preview tunnel did not connect." : failure) }
    }

    private func receive(_ line: String) {
        if line.contains("Local forwarding listening on 127.0.0.1 port \(localPort)") { ready = true }
        if !line.hasPrefix("debug") { failure = String((failure + line + "\n").suffix(2_048)) }
    }

    public var isAlive: Bool { process.isRunning }
    public func close() { process.terminate(); outputTask?.cancel(); errorTask?.cancel() }
    deinit { process.terminate(); outputTask?.cancel(); errorTask?.cancel() }
}
