import Foundation
import Synchronization

/// The whole of `bloom-bridge`, the stdio shim Bloom ships in its own bundle.
///
/// It speaks no MCP. After a hello it copies lines from stdin to the socket and from the socket to
/// stdout, and Bloom answers `initialize`, `tools/list` and `tools/call` at the other end. That
/// division is the point: Sparkle replaces the bundle underneath a running app, so anything the
/// shim knows is something that can skew against the app that is actually running, while the
/// phases after this one add five tools and no shim work at all.
///
/// It lives in BloomCore rather than in the executable target because `Tools/test-core.sh` mirrors
/// only BloomCore and its tests into a throwaway package: an executable target is invisible to the
/// suite, so anything worth testing has to be on this side of the line and the target's own
/// `main.swift` has to be thin enough that having no test for it is honest.
public enum BridgeShim {
    /// What the process exits with. Distinct numbers because the CLI prints them, and "the shim
    /// exited 1" says nothing that "Bloom is not running" does not say better.
    public enum Exit {
        public static let ok: Int32 = 0
        public static let notConfigured: Int32 = 64
        public static let cannotReachBloom: Int32 = 69
        public static let refused: Int32 = 70
    }

    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shim: String? = CommandLine.arguments.first
    ) async -> Int32 {
        if let complaint = missingEnvironment(environment) {
            complain(complaint)
            return Exit.notConfigured
        }
        let socketPath = environment[BridgeProtocol.socketVariable] ?? ""
        let token = environment[BridgeProtocol.tokenVariable] ?? ""
        let role = environment[BridgeProtocol.roleVariable] ?? BridgeRole.parent.rawValue

        let connection: UnixSocketConnection
        do {
            connection = try UnixSocketConnection.connect(to: socketPath)
        } catch {
            // The ordinary case, and it deserves a sentence rather than an errno: Bloom has quit
            // and somebody is running the CLI by hand from a config file Bloom left behind.
            complain("bloom-bridge could not reach Bloom on \(socketPath). Is Bloom running?")
            return Exit.cannotReachBloom
        }

        var iterator = connection.lines.makeAsyncIterator()
        let hello = BridgeHello(token: token, role: role, shim: shim)
        guard let data = try? JSONEncoder().encode(hello) else {
            complain("bloom-bridge could not build its hello frame.")
            return Exit.notConfigured
        }
        connection.writeLine(String(decoding: data, as: UTF8.self))

        guard let reply = await iterator.next() else {
            complain("Bloom closed the bridge without answering. Quit and reopen Bloom.")
            connection.close()
            return Exit.cannotReachBloom
        }
        let welcome = (reply.data(using: .utf8)).flatMap { try? JSONDecoder().decode(BridgeWelcome.self, from: $0) }
        guard let welcome, welcome.accepted else {
            complain(welcome?.problem ?? "Bloom refused the bridge connection.")
            connection.close()
            return Exit.refused
        }

        // Whether the CLI has closed its end of stdin. Read once the socket has gone quiet, and
        // it is the whole difference between the two ways this loop can end. See below.
        let shutdownAsked = ShutdownFlag()
        relayStandardInput(to: connection, shutdownAsked: shutdownAsked)
        // The same iterator the welcome came out of. An `AsyncStream` has one consumer, and a
        // second `for await` over `lines` would be a second iterator racing this one for frames.
        while let line = await iterator.next() {
            write(line + "\n", to: STDOUT_FILENO)
        }
        connection.close()

        // Two things end that loop and they mean opposite things. Either the CLI closed stdin and
        // the handler below closed the socket, which is an ordinary shutdown, or Bloom went away
        // while the CLI was still talking to it. The shim could not tell them apart and reported
        // both as success, so a `tools/call` sent to a Bloom that quit mid-answer left the CLI
        // with a server that exited 0 having written nothing at all: no reply, no complaint, no
        // status. The model waits on a tool result that is never coming, and the one thing that
        // could have told it otherwise stayed silent. A wrong answer is recoverable; that is not.
        guard shutdownAsked.wasAsked else {
            complain("Bloom closed the bridge before answering. Quit and reopen Bloom, then try again.")
            return Exit.cannotReachBloom
        }
        return Exit.ok
    }

    /// stdin to the socket, off the same readability handler the rest of Bloom uses for a pipe.
    ///
    /// The CLI closing its end of stdin is how an MCP server is told to shut down, so end of file
    /// closes the socket, which ends the loop above and exits the process. Without that the shim
    /// would outlive every agent that ever launched it.
    private static func relayStandardInput(
        to connection: UnixSocketConnection,
        shutdownAsked: ShutdownFlag
    ) {
        let input = FileHandle.standardInput
        let buffer = LineBuffer()
        input.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                input.readabilityHandler = nil
                shutdownAsked.ask()
                connection.close()
                return
            }
            for line in buffer.take(data) { connection.writeLine(line) }
        }
    }

    /// What is missing from the environment, as the sentence to print, or nil when nothing is.
    ///
    /// It names the variables that are actually absent. The sentence used to say "Neither was
    /// set" whichever of the two was missing, so somebody who had set the socket and lost the
    /// token was told to go and look at both, and the one thing the message could have told them
    /// was the one thing it did not.
    static func missingEnvironment(_ environment: [String: String]) -> String? {
        let missing = [BridgeProtocol.socketVariable, BridgeProtocol.tokenVariable]
            .filter { (environment[$0] ?? "").isEmpty }
        guard !missing.isEmpty else { return nil }

        let absent = missing.count == 2
            ? "Neither was set"
            : "\(missing[0]) was not set"
        return """
            bloom-bridge is launched by Bloom and takes \(BridgeProtocol.socketVariable) and \
            \(BridgeProtocol.tokenVariable) from its environment. \(absent), so there is \
            nothing to connect to.
            """
    }

    /// Set on the file handle's own queue and read from the task that outlives it, so it is
    /// shared state and needs a lock. A class, because `Mutex` is noncopyable and an escaping
    /// closure has to capture something it can hold.
    private final class ShutdownFlag: Sendable {
        private let asked = Mutex(false)

        func ask() { asked.withLock { $0 = true } }

        var wasAsked: Bool { asked.withLock { $0 } }
    }

    private static func complain(_ sentence: String) {
        write(sentence + "\n", to: STDERR_FILENO)
    }

    /// `write(2)` rather than `FileHandle.write`, which raises an Objective-C exception on a
    /// broken pipe that no Swift `catch` can see.
    private static func write(_ text: String, to descriptor: Int32) {
        var payload = Array(text.utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeMutableBufferPointer { bytes in
                Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += written
        }
    }
}
