import Foundation

/// `connect` is only a relay. Ending SSH or stdin closes that connection and leaves `serve`
/// running under its own process manager, with every agent still owned by the server.
public enum ServerCommandLine {
    public static let usage = """
    Usage: bloom-server serve|connect --data-dir /absolute/path

    serve     Run the standalone server in the foreground.
    connect   Relay the versioned JSON protocol over stdin/stdout.

    Use launchd to keep serve running independently of a terminal or SSH connection.
    The directory is separate from the desktop app's data. This preview requires macOS 26.
    """

    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        if arguments.isEmpty || arguments == ["--help"] {
            print(usage)
            return 0
        }
        guard arguments.count == 3, arguments[1] == "--data-dir",
              ["serve", "connect"].contains(arguments[0]) else {
            complain(usage)
            return 64
        }
        do {
            if arguments[0] == "connect" {
                let connection = try UnixSocketConnection.connect(to: ServerDaemon.socketPath(directory: arguments[2]))
                await relay(connection)
            } else {
                let daemon = try await ServerDaemon.start(directory: arguments[2])
                complain("Bloom server listening at \(daemon.socketPath)")
                await waitForTermination()
                await daemon.shutdown()
            }
            return 0
        } catch {
            complain(error.localizedDescription)
            return 1
        }
    }

    private static func relay(_ connection: UnixSocketConnection) async {
        let input = FileHandle.standardInput
        let buffer = LineBuffer()
        input.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                input.readabilityHandler = nil
                connection.close()
            } else {
                for line in buffer.take(data) { connection.writeLine(line) }
            }
        }
        for await line in connection.lines {
            do { try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) } catch { break }
        }
        input.readabilityHandler = nil
        connection.close()
    }

    private static func waitForTermination() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sources = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            return source
        }
        for await _ in stream { break }
        for source in sources { source.cancel() }
    }

    private static func complain(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }
}
