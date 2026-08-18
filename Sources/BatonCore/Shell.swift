import Foundation

/// Result of a finished subprocess.
public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }

    /// stdout with trailing newlines removed, the form almost every caller wants.
    public var trimmed: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var lines: [String] {
        trimmed.isEmpty ? [] : trimmed.components(separatedBy: "\n")
    }
}

public struct ShellError: Error, CustomStringConvertible {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var description: String {
        "`\(command)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Every subprocess in Baton goes through here.
///
/// Nothing uses a login shell: commands are exec'd directly so an argument containing a space
/// or a quote can never be reinterpreted. `Shell.script` is the deliberate exception, used for
/// user-authored setup and run scripts.
public enum Shell {
    /// Directories added to PATH for spawned processes, because GUI apps launched from Finder
    /// inherit a minimal PATH that lacks Homebrew, mise, fnm, and friends.
    public static let extraPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",
            // Node installs put binaries wherever the user's package manager decided. `codex`
            // lives in .npm-packages/bin on this machine, and a Finder launch would otherwise
            // report it as not installed while a terminal launch found it.
            "\(home)/.npm-packages/bin",
            "\(home)/.volta/bin",
            "\(home)/.yarn/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.composer/vendor/bin",
            "\(home)/bin",
        ]
    }()

    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"]?.components(separatedBy: ":") ?? []
        var seen = Set<String>()
        let merged = (existing + extraPaths).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Resolve an executable name to an absolute path using the merged PATH.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in environment()["PATH"]?.components(separatedBy: ":") ?? [] {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        stdin: String? = nil,
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        guard let path = which(executable) else {
            throw ShellError(command: executable, status: 127, stderr: "\(executable) not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment(extra: env)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe { process.standardInput = inPipe }

        let collector = OutputCollector()

        // Read each pipe to EOF on its own thread rather than through `readabilityHandler`.
        //
        // The handler approach has a race that loses output: clearing the handler after the
        // process exits can discard whatever the dispatch source had already buffered, and
        // draining with `readToEnd` afterwards then returns nothing. It is rare and load
        // dependent, which is the worst kind: under a parallel test run it turned up as an empty
        // `git diff`, and in the app it would have been an empty diff shown as though the file
        // had not changed. Reading to EOF cannot lose anything, and EOF is also the signal that
        // the child is done writing.
        let outReader = Thread {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            collector.appendOut(data)
            collector.finishOut()
        }
        let errReader = Thread {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            collector.appendErr(data)
            collector.finishErr()
        }
        outReader.stackSize = 512 * 1_024
        errReader.stackSize = 512 * 1_024

        try process.run()

        outReader.start()
        errReader.start()

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let timeoutTask: Task<Void, Never>? = timeout.map { duration in
            Task {
                try? await Task.sleep(for: duration)
                if process.isRunning { process.terminate() }
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        timeoutTask?.cancel()

        // The child has exited, but its output is only complete once both pipes have reached EOF.
        // Returning before that is exactly how output goes missing.
        await collector.waitForEOF()

        return ShellResult(
            status: process.terminationStatus,
            stdout: collector.stdoutString,
            stderr: collector.stderrString
        )
    }

    /// Run and throw unless the exit status is zero.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, cwd: cwd, env: env, timeout: timeout)
        guard result.ok else {
            throw ShellError(
                command: ([executable] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    /// Run a user-authored script through zsh. Used only for setup and run scripts, where the
    /// whole point is that the user wrote shell.
    @discardableResult
    public static func script(
        _ source: String,
        cwd: String,
        env: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        try await run("/bin/zsh", ["-c", source], cwd: cwd, env: env, timeout: timeout)
    }
}

/// Thread-safe accumulator for the two output streams, and the gate that says both are complete.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    /// One count per stream. Waiting on both is what guarantees nothing is still in flight.
    private let eof = DispatchGroup()

    init() {
        eof.enter()
        eof.enter()
    }

    func appendOut(_ data: Data) {
        lock.lock(); out.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock(); err.append(data); lock.unlock()
    }

    func finishOut() { eof.leave() }
    func finishErr() { eof.leave() }

    func waitForEOF() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eof.notify(queue: .global()) { continuation.resume() }
        }
    }

    var stdoutString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderrString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}
