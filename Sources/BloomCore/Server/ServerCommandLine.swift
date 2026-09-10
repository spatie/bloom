import Foundation
#if os(Linux)
import Glibc
#endif

/// `connect` is only a relay. Ending SSH or stdin closes that connection and leaves `serve`
/// running under its own process manager, with every agent still owned by the server.
public enum ServerCommandLine {
    public static let usage = """
    Usage: bloom-server serve|connect --data-dir /absolute/path
           bloom-server serve|connect --application-id be.spatie.bloom.dev

           bloom-server doctor --data-dir /absolute/path [--json]

    doctor    Check tools and resources as the server account without changing anything.
    serve     Run the standalone server in the foreground.
    connect   Relay the versioned JSON protocol over stdin/stdout.

    Use launchd on macOS or systemd on Linux to keep serve running independently of a terminal.
    The directory is separate from the desktop app's data. The server runs on macOS 26 or Linux.
    """

    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        SystemCalls.configurePipeWrites(STDOUT_FILENO)
        if arguments.isEmpty || arguments == ["--help"] {
            print(usage)
            return 0
        }
        if arguments.first == "doctor" { return await doctor(arguments: arguments) }
        guard arguments.count == 3, ["--data-dir", "--application-id"].contains(arguments[1]),
              ["serve", "connect"].contains(arguments[0]) else {
            complain(usage)
            return 64
        }
        do {
            let directory = arguments[1] == "--application-id"
                ? try LocalServerIdentity(bundleID: arguments[2]).directory()
                : arguments[2]
            if arguments[0] == "connect" {
                try await ServerTerminalRelay.run(directory: directory)
            } else {
                var gatewayGroupID: UInt32?
                if let value = ProcessInfo.processInfo.environment["BLOOM_SERVER_GATEWAY_GID"] {
                    guard let parsed = UInt32(value), parsed > 0 else {
                        throw ServerFailure("BLOOM_SERVER_GATEWAY_GID must name a non-root group ID.")
                    }
                    gatewayGroupID = parsed
                }
                let daemon = try await ServerDaemon.start(directory: directory, gatewayGroupID: gatewayGroupID)
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

    private static func doctor(arguments: [String]) async -> Int32 {
        guard arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--json"),
              arguments[1] == "--data-dir", arguments[2].hasPrefix("/") else {
            complain(usage)
            return 64
        }
        let report = await ServerDiagnosticsCollector.collect(directory: arguments[2])
        if arguments.last == "--json" {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } catch {
                complain("Could not encode server checks.")
                return 1
            }
        } else { print(report.text) }
        return report.needsAttention ? 1 : 0
    }

    static func relay(_ connection: UnixSocketConnection, initial: Data = Data()) async {
        let input = FileHandle.standardInput
        let buffer = LineBuffer()
        for line in buffer.take(initial) { connection.writeLine(line) }
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
        #if canImport(os)
        CoreLogger(subsystem: "be.spatie.bloom", category: "server").error("\(text, privacy: .public)")
        #endif
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }
}
